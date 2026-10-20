/// A `SpeechStream` over a session-based recognizer that ends the session at each pause
/// so its final arrives at once, then carries on in a fresh one.
///
/// Built for Apple's SpeechTranscriber, which settles a phrase 1 to 2 s after the
/// speaker stops. Forcing it with `finalize(through:)` mid-stream loses or garbles the
/// words that follow, so ending the session is the only reliable way to hurry a final.
/// Audio that arrives while one session ends and the next starts is held and replayed,
/// so nothing is lost, and every session's times are shifted onto the channel timeline.
public actor RotatingSpeechStream: SpeechStream {
    public struct Configuration: Sendable {
        public var finalization: FinalizationTrigger.Configuration
        /// Ending a session normally takes about 0.1 s. One that has not ended after this
        /// is cancelled, and one that ignores that too is abandoned. Its volatile words
        /// become final either way.
        public var finishTimeout: Duration
        /// A recognizer that fails this many times in a row, without a result in between,
        /// ends the stream with its error.
        public var maxFailuresInARow: Int
        public var retryDelay: Duration

        public init(
            finalization: FinalizationTrigger.Configuration = FinalizationTrigger.Configuration(),
            finishTimeout: Duration = .seconds(2),
            maxFailuresInARow: Int = 3,
            retryDelay: Duration = .milliseconds(250)
        ) {
            self.finalization = finalization
            self.finishTimeout = finishTimeout
            self.maxFailuresInARow = maxFailuresInARow
            self.retryDelay = retryDelay
        }
    }

    public nonisolated let events: AsyncThrowingStream<SpeechEvent, any Error>
    private let output: AsyncThrowingStream<SpeechEvent, any Error>.Continuation
    private let recognizer: any SessionRecognizer
    private let configuration: Configuration
    private var trigger: FinalizationTrigger
    private var mapper = VolatileResultMapper()

    private struct ActiveSession {
        let id: Int
        let session: any RecognizerSession
        let consumer: Task<Void, Never>
    }

    /// The session taking audio. Nil while it is being replaced; audio is held meanwhile.
    private var current: ActiveSession?
    private var held: [[Int16]] = []
    private var replacement: Task<Void, Never>?
    private var samplesSent = 0
    private var lastSessionID = 0
    /// Results from any other session are stale and ignored.
    private var mappedSessionID = 0
    private var failuresInARow = 0
    private var isFinishing = false
    private var failure: (any Error)?

    public static func open(
        recognizer: any SessionRecognizer,
        configuration: Configuration = Configuration()
    ) async throws -> RotatingSpeechStream {
        let stream = RotatingSpeechStream(recognizer: recognizer, configuration: configuration)
        try await stream.startFirstSession()
        return stream
    }

    private init(recognizer: any SessionRecognizer, configuration: Configuration) {
        (events, output) = AsyncThrowingStream<SpeechEvent, any Error>.makeStream()
        self.recognizer = recognizer
        self.configuration = configuration
        trigger = FinalizationTrigger(configuration: configuration.finalization)
    }

    public func send(_ chunk: AudioChunk) async throws {
        if let failure {
            throw failure
        }
        if isFinishing || chunk.samples.isEmpty {
            return
        }
        if let current {
            do {
                try current.session.send(chunk.samples)
            } catch {
                fail(error)
                throw error
            }
        } else {
            held.append(chunk.samples)
        }
        samplesSent += chunk.samples.count
        if trigger.process(chunk.samples) {
            replaceSession()
        }
    }

    public func finish() async {
        if isFinishing {
            return
        }
        isFinishing = true
        await waitForReplacement()
        if let current {
            self.current = nil
            await close(current)
        }
        output.finish()
    }

    /// Waits until no session is being replaced. Tests use it to step the stream.
    func waitForReplacement() async {
        while let replacement {
            await replacement.value
        }
    }

    private func startFirstSession() async throws {
        current = try await startSession(at: 0)
    }

    private func startSession(at offset: Double) async throws -> ActiveSession {
        let session = try await recognizer.startSession()
        lastSessionID += 1
        let id = lastSessionID
        mappedSessionID = id
        mapper.beginSession(at: offset)
        let consumer = Task { await self.consume(session, id: id) }
        return ActiveSession(id: id, session: session, consumer: consumer)
    }

    private func consume(_ session: any RecognizerSession, id: Int) async {
        do {
            for try await result in session.results {
                receive(result, from: id)
            }
            sessionEnded(id, error: nil)
        } catch {
            sessionEnded(id, error: error)
        }
    }

    private func receive(_ result: RecognizerResult, from id: Int) {
        guard id == mappedSessionID else {
            return
        }
        failuresInARow = 0
        emit(mapper.map(result))
    }

    /// A session's results ended. Expected when this stream closed it; otherwise the
    /// recognizer stopped by itself and a fresh session takes over.
    private func sessionEnded(_ id: Int, error: (any Error)?) {
        guard let current, current.id == id, !isFinishing else {
            return
        }
        failuresInARow += 1
        if failuresInARow >= configuration.maxFailuresInARow {
            fail(error ?? RotatingSpeechStreamError.recognizerStopped)
        } else {
            replaceSession()
        }
    }

    private func replaceSession() {
        guard let old = current, replacement == nil, !isFinishing else {
            return
        }
        current = nil
        let offset = Double(samplesSent) / Double(AudioChunk.sampleRate)
        replacement = Task { await self.replace(old, startingAt: offset) }
    }

    private func replace(_ old: ActiveSession, startingAt offset: Double) async {
        await close(old)
        await reopen(at: offset)
        replacement = nil
    }

    private func close(_ active: ActiveSession) async {
        let session = active.session
        Task { await session.finish() }
        if await !waitFor(active.consumer, upTo: configuration.finishTimeout) {
            Task { await session.cancel() }
            if await !waitFor(active.consumer, upTo: configuration.finishTimeout) {
                mappedSessionID = 0
            }
        }
        emit(mapper.endSession())
    }

    private func reopen(at offset: Double) async {
        guard let active = await startSessionRetrying(at: offset) else {
            return
        }
        // No suspension from here on, so no new chunk can slip in ahead of the held ones.
        current = active
        do {
            for samples in held {
                try active.session.send(samples)
            }
            held.removeAll()
        } catch {
            fail(error)
        }
    }

    private func startSessionRetrying(at offset: Double) async -> ActiveSession? {
        let attempts = max(configuration.maxFailuresInARow, 1)
        for attempt in 1...attempts {
            do {
                return try await startSession(at: offset)
            } catch {
                if attempt == attempts {
                    fail(error)
                } else {
                    try? await Task.sleep(for: configuration.retryDelay)
                }
            }
        }
        return nil
    }

    private func emit(_ events: [SpeechEvent]) {
        for event in events {
            output.yield(event)
        }
        trigger.recognizerSettled(through: mapper.finalizedThrough)
    }

    private func fail(_ error: any Error) {
        if failure != nil {
            return
        }
        failure = error
        held.removeAll()
        if let current {
            self.current = nil
            let session = current.session
            Task { await session.cancel() }
        }
        emit(mapper.endSession())
        output.finish(throwing: error)
    }

    /// True if `task` completed within `limit`. The task keeps running either way.
    private func waitFor(_ task: Task<Void, Never>, upTo limit: Duration) async -> Bool {
        let (outcome, report) = AsyncStream<Bool>.makeStream()
        Task {
            await task.value
            report.yield(true)
        }
        let timer = Task {
            try await Task.sleep(for: limit)
            report.yield(false)
        }
        for await completed in outcome {
            timer.cancel()
            return completed
        }
        return false
    }
}

public enum RotatingSpeechStreamError: Error, CustomStringConvertible {
    case recognizerStopped

    public var description: String {
        switch self {
        case .recognizerStopped:
            "The speech recognizer stopped by itself, several times in a row."
        }
    }
}
