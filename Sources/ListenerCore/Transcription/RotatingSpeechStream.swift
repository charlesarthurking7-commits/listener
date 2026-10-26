/// A `SpeechStream` over a session-based recognizer that ends the session at each pause
/// so its final arrives at once, then carries on in a fresh one.
///
/// Built for Apple's SpeechTranscriber, which settles a phrase 1 to 2 s after the
/// speaker stops. Forcing it with `finalize(through:)` mid-stream loses or garbles the
/// words that follow, so ending the session is the only reliable way to hurry a final.
/// Audio that arrives while one session ends and the next starts is held and replayed,
/// so nothing is lost, and every session's times are shifted onto the channel timeline.
///
/// A session ends at the sample where the pause completed and the next one starts right
/// there, so the word after the pause reaches the next session whole. A session that
/// stops by itself is replaced by one that hears everything it had not settled.
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

    /// Most audio kept for a session that has to hear it again, in samples. Only reached
    /// when nothing has settled for a long time, which in practice means silence.
    static let replayLimit = 30 * AudioChunk.sampleRate

    public nonisolated let events: AsyncThrowingStream<SpeechEvent, any Error>
    private let output: AsyncThrowingStream<SpeechEvent, any Error>.Continuation
    private let recognizer: any SessionRecognizer
    private let configuration: Configuration
    private var trigger: FinalizationTrigger
    private var mapper = VolatileResultMapper()
    private var unsettled = UnsettledAudio()

    private struct ActiveSession {
        let id: Int
        let session: any RecognizerSession
        let consumer: Task<Void, Never>
    }

    /// The session taking audio. Nil while it is being replaced; audio is held meanwhile.
    private var current: ActiveSession?
    /// What the next session hears first, then the audio that arrived while it started.
    private var held: [[Int16]] = []
    private var replacement: Task<Void, Never>?
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
        let chunkStart = unsettled.end
        unsettled.append(chunk.samples, keeping: Self.replayLimit)
        let pauseEnd = trigger.process(chunk.samples)
        guard let current else {
            held.append(chunk.samples)
            return
        }
        do {
            try current.session.send(pauseEnd.map { Array(chunk.samples[..<$0]) } ?? chunk.samples)
        } catch {
            fail(error)
            throw error
        }
        if let pauseEnd {
            // The next session starts exactly where the pause completed. Starting it on
            // the end of the pause instead made Apple's recognizer worse on every fixture.
            replaceSession(
                startingAt: chunkStart + pauseEnd, replaying: [Array(chunk.samples[pauseEnd...])],
                settlingVolatile: true)
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
            // Its volatile words were only a guess at audio it never settled, which the
            // next session hears again instead.
            replaceSession(startingAt: unsettled.start, replaying: [Array(unsettled.samples)], settlingVolatile: false)
        }
    }

    /// Starts the next session at stream sample `start`, hearing `audio` first.
    private func replaceSession(startingAt start: Int, replaying audio: [[Int16]], settlingVolatile: Bool) {
        guard let old = current, replacement == nil, !isFinishing else {
            return
        }
        current = nil
        held = audio
        let offset = Double(start) / Double(AudioChunk.sampleRate)
        replacement = Task { await self.replace(old, startingAt: offset, settlingVolatile: settlingVolatile) }
    }

    private func replace(_ old: ActiveSession, startingAt offset: Double, settlingVolatile: Bool) async {
        await close(old, settlingVolatile: settlingVolatile)
        await reopen(at: offset)
        replacement = nil
    }

    private func close(_ active: ActiveSession, settlingVolatile: Bool = true) async {
        let session = active.session
        Task { await session.finish() }
        if await !waitFor(active.consumer, upTo: configuration.finishTimeout) {
            Task { await session.cancel() }
            if await !waitFor(active.consumer, upTo: configuration.finishTimeout) {
                mappedSessionID = 0
            }
        }
        emit(settlingVolatile ? mapper.endSession() : mapper.discardVolatile())
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
        unsettled.drop(before: Int((mapper.finalizedThrough * Double(AudioChunk.sampleRate)).rounded()))
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

/// A stream's audio from the first sample its recognizer has not settled. Positions
/// count samples from the start of the stream. Dropping from the front only moves
/// `head`; the array is compacted once the dead part outgrows the live one.
private struct UnsettledAudio {
    /// Stream position of the oldest sample kept.
    private(set) var start = 0
    private var buffer: [Int16] = []
    private var head = 0

    /// Stream position just past the newest sample.
    var end: Int { start + buffer.count - head }
    var samples: ArraySlice<Int16> { buffer[head...] }

    /// Adds the stream's next samples, keeping at most `limit` in all.
    mutating func append(_ samples: [Int16], keeping limit: Int) {
        buffer.append(contentsOf: samples)
        drop(before: end - limit)
    }

    mutating func drop(before position: Int) {
        let count = min(position, end) - start
        guard count > 0 else {
            return
        }
        head += count
        start += count
        if head > buffer.count / 2 && head >= AudioChunk.sampleRate {
            buffer.removeFirst(head)
            head = 0
        }
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
