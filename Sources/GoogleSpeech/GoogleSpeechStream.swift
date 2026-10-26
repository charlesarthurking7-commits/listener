import Foundation
import GRPCCore
import ListenerCore

/// Limits and timings for a stream. The defaults suit Google; tests shrink them.
struct StreamTuning: Sendable {
    /// Move to a new stream at the first final after this long.
    var rotateAfter: Duration
    /// A pause in Google's voice activity shorter than this stays inside an utterance,
    /// as it would inside a turn.
    var utterancePause: Duration
    /// Move to a new stream now, final or not. Google ends streams at five minutes.
    var hardLimit: Duration = .seconds(280)
    /// 100 ms of audio per request, as Google recommends. The limit is 15,360 bytes.
    var frameBytes = 3_200
    /// Most audio kept for replay after a stream ends.
    var replayLimit: Duration = .seconds(30)
    /// Audio replayed after an idle stream is replaced, in case speech had just begun.
    var idleReplay: Duration = .seconds(5)
    var firstBackoff: Duration = .milliseconds(250)
    var maxBackoff: Duration = .seconds(8)
    /// Consecutive failed reconnects before the stream gives up.
    var maxAttempts = 10
    /// A call that ran this long counts as healthy even without results (silence).
    var healthyAfter: Duration = .seconds(30)
    /// How long `finish()` waits for the last finals.
    var finishTimeout: Duration = .seconds(10)

    init(settings: SpeechSettings, turns: TurnSettings) {
        rotateAfter = .seconds(max(settings.rotateAfterSeconds, 0))
        utterancePause = .milliseconds(turns.silenceMs)
    }

    func backoff(attempt: Int) -> Duration {
        let base = firstBackoff.inSeconds * pow(2, Double(attempt - 1))
        return .seconds(min(base, maxBackoff.inSeconds) * Double.random(in: 0.8...1.2))
    }

    static func samples(in duration: Duration) -> Int {
        Int(duration.inSeconds * Double(AudioChunk.sampleRate))
    }
}

/// One channel's recognition. Each Google stream lasts at most five minutes, so this
/// runs a series of them ("generations") behind a single `SpeechStream`: it rotates to
/// a new one after `rotateAfter`, reconnects after transient errors, and each time
/// replays the audio Google has not finalised yet, so no speech is lost or repeated.
actor GoogleSpeechStream: SpeechStream {
    nonisolated let events: AsyncThrowingStream<SpeechEvent, any Error>
    private let output: AsyncThrowingStream<SpeechEvent, any Error>.Continuation

    private let client: any Google_Cloud_Speech_V2_Speech.ClientProtocol
    private let tokens: any AccessTokenProvider
    private let setup: RecognitionSetup
    private let tuning: StreamTuning

    private enum Phase {
        case running
        /// `finish()` was called: half-close and wait for the last finals.
        case finishing
        case closed
    }

    private struct Generation {
        let id: Int
        let startedAt = ContinuousClock.now
        let requests: AsyncStream<RecognizeRequest>.Continuation
        var call: Task<Void, any Error>?
        var sentSamples: Int
        var sawResponse = false
        var replaced = false
    }

    private enum Outcome {
        case finished
        case replaced
        case failed(any Error, healthy: Bool)
    }

    private var timeline: ChannelTimeline
    private var phase = Phase.running
    private var current: Generation?
    private var generations = 0
    private var failure: GoogleSpeechError?
    private var needsFreshToken = false
    private var driver: Task<Void, Never>?
    private var wakeUp: CheckedContinuation<Void, Never>?

    init(
        client: any Google_Cloud_Speech_V2_Speech.ClientProtocol,
        tokens: any AccessTokenProvider,
        setup: RecognitionSetup,
        tuning: StreamTuning
    ) {
        (events, output) = AsyncThrowingStream.makeStream(of: SpeechEvent.self)
        self.client = client
        self.tokens = tokens
        self.setup = setup
        self.tuning = tuning
        timeline = ChannelTimeline(
            replayLimit: StreamTuning.samples(in: tuning.replayLimit),
            utterancePause: StreamTuning.samples(in: tuning.utterancePause))
    }

    func start() {
        output.onTermination = { [weak self] _ in
            Task { await self?.close(nil) }
        }
        driver = Task { await run() }
    }

    func send(_ chunk: AudioChunk) async throws {
        if let failure {
            throw failure
        }
        guard phase == .running, !chunk.samples.isEmpty else { return }
        timeline.append(chunk.samples)

        guard var generation = current, !generation.replaced else {
            wake()
            return
        }
        for request in RecognitionSetup.audioRequests(chunk.samples[...], frameBytes: tuning.frameBytes) {
            generation.requests.yield(request)
        }
        generation.sentSamples += chunk.samples.count
        current = generation
        if age(of: generation) >= tuning.hardLimit {
            replaceStream(trimIdleAudio: true)
        }
    }

    func finish() async {
        guard phase == .running else {
            await driver?.value
            return
        }
        guard timeline.received > 0 else {
            close(nil)
            await driver?.value
            return
        }
        phase = .finishing
        current?.requests.finish()
        wake()
        let timeout = Task { [tuning] in
            try await Task.sleep(for: tuning.finishTimeout)
            close(nil)
        }
        await driver?.value
        timeout.cancel()
    }

    // MARK: Driver

    private func run() async {
        var attempts = 0
        var refreshedAfterRejection = false
        while await waitForWork() {
            switch await runGeneration() {
            case .finished:
                close(nil)
            case .replaced:
                attempts = 0
            case .failed(let error, let healthy):
                if healthy {
                    attempts = 0
                    refreshedAfterRejection = false
                }
                switch setup.response(to: error) {
                case .refreshToken where !refreshedAfterRejection:
                    refreshedAfterRejection = true
                    needsFreshToken = true
                case .refreshToken:
                    close(
                        GoogleSpeechError(
                            .credentials,
                            "Google rejected the access token for Speech-to-Text (\(describe(error))). "
                                + "Run `gcloud auth application-default login` again."))
                case .reconnectWhenAudioArrives:
                    attempts = 0
                    for event in timeline.abandonUnsettled() {
                        output.yield(event)
                    }
                case .retry where attempts < tuning.maxAttempts:
                    attempts += 1
                    try? await Task.sleep(for: tuning.backoff(attempt: attempts))
                case .retry:
                    close(
                        GoogleSpeechError(
                            .connectionLost,
                            "Lost the connection to Google Speech-to-Text and could not reconnect after "
                                + "\(attempts) attempts. Last error: \(describe(error))"))
                case .fail(let error):
                    close(error)
                }
            }
        }
        close(nil)
    }

    /// Waits until a new generation should start. False when the stream is done.
    private func waitForWork() async -> Bool {
        while true {
            switch phase {
            case .closed:
                return false
            case .finishing:
                return timeline.hasUnsettledAudio
            case .running:
                // The first stream opens at once so that setup errors show up at Start.
                // Later ones wait for audio, so silence-skipping callers don't keep
                // empty streams open.
                if generations == 0 || timeline.hasUnsettledAudio {
                    return true
                }
                await withCheckedContinuation { wakeUp = $0 }
            }
        }
    }

    private func runGeneration() async -> Outcome {
        let token: String
        do {
            token = needsFreshToken ? try await tokens.refreshAccessToken() : try await tokens.accessToken()
            needsFreshToken = false
        } catch {
            return .failed(error, healthy: false)
        }
        guard phase != .closed else { return .finished }

        let (id, requests) = beginGeneration()
        let metadata = setup.metadata(token: token)
        let call = Task { [client] in
            try await client.streamingRecognize(
                metadata: metadata,
                requestProducer: { writer in
                    for await request in requests {
                        try await writer.write(request)
                    }
                },
                onResponse: { response in
                    for try await message in response.messages {
                        await self.receive(message, generation: id)
                    }
                })
        }
        current?.call = call
        return endGeneration(id, result: await call.result)
    }

    private func beginGeneration() -> (Int, AsyncStream<RecognizeRequest>) {
        generations += 1
        let (requests, continuation) = AsyncStream.makeStream(of: RecognizeRequest.self)
        let replay = timeline.beginStream()
        continuation.yield(setup.configRequest)
        for request in RecognitionSetup.audioRequests(replay, frameBytes: tuning.frameBytes) {
            continuation.yield(request)
        }
        if phase == .finishing {
            continuation.finish()
        }
        current = Generation(id: generations, requests: continuation, sentSamples: replay.count)
        return (generations, requests)
    }

    private func endGeneration(_ id: Int, result: Result<Void, any Error>) -> Outcome {
        guard let generation = current, generation.id == id else { return .finished }
        current = nil
        generation.requests.finish()
        let healthy = generation.sawResponse || generation.startedAt.duration(to: .now) >= tuning.healthyAfter

        if phase == .closed {
            return .finished
        }
        if generation.replaced {
            return .replaced
        }
        switch result {
        case .success where phase == .finishing:
            return .finished
        case .success:
            // Google closed the stream without being asked. Reconnect, but through
            // the backoff in case it keeps doing so.
            return .failed(RPCError(code: .unavailable, message: "Google closed the stream"), healthy: healthy)
        case .failure(let error):
            return .failed(error, healthy: healthy)
        }
    }

    private func receive(_ response: RecognizeResponse, generation id: Int) {
        guard phase != .closed, var generation = current, generation.id == id, !generation.replaced else { return }
        generation.sawResponse = true
        current = generation

        for event in timeline.events(for: response) {
            output.yield(event)
        }
        if phase == .running, response.results.contains(where: \.isFinal), age(of: generation) >= tuning.rotateAfter {
            replaceStream(trimIdleAudio: false)
        }
    }

    /// Ends the current call without waiting for Google: everything it has not
    /// finalised is replayed to the next one, so nothing it would still say is lost.
    private func replaceStream(trimIdleAudio: Bool) {
        guard var generation = current, !generation.replaced else { return }
        if trimIdleAudio && timeline.isIdle {
            timeline.keepNewest(StreamTuning.samples(in: tuning.idleReplay))
        }
        generation.replaced = true
        current = generation
        generation.requests.finish()
        generation.call?.cancel()
    }

    private func age(of generation: Generation) -> Duration {
        let audio = Duration.seconds(Double(generation.sentSamples) / Double(AudioChunk.sampleRate))
        return max(audio, generation.startedAt.duration(to: .now))
    }

    private func wake() {
        wakeUp?.resume()
        wakeUp = nil
    }

    private func close(_ error: GoogleSpeechError?) {
        guard phase != .closed else { return }
        phase = .closed
        failure = error
        current?.requests.finish()
        current?.call?.cancel()
        driver?.cancel()
        wake()
        if let error {
            output.finish(throwing: error)
        } else {
            output.finish()
        }
    }
}

private func describe(_ error: any Error) -> String {
    if let error = error as? RPCError {
        return error.message.isEmpty ? "\(error.code)" : "\(error.code): \(error.message)"
    }
    return "\(error)"
}
