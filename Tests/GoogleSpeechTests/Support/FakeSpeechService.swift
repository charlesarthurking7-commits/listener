import Foundation
import GRPCCore
import GRPCInProcessTransport
import ListenerCore

@testable import GoogleSpeech

/// What a scripted call does. Runs on the fake server for one StreamingRecognize call.
typealias CallScript = @Sendable (FakeCall) async throws -> Void

/// Google's Speech service as the tests need it: each StreamingRecognize call runs the
/// next script in line and every request is recorded.
struct FakeSpeechService: Google_Cloud_Speech_V2_Speech.StreamingServiceProtocol {
    let scripts: ScriptQueue
    let recorder: CallRecorder

    func streamingRecognize(
        request: StreamingServerRequest<RecognizeRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<RecognizeResponse> {
        let index = await recorder.startCall(metadata: request.metadata)
        let script = await scripts.next()
        return StreamingServerResponse { writer in
            let call = FakeCall(
                index: index, metadata: request.metadata, requests: request.messages, writer: writer,
                recorder: recorder)
            try await script(call)
            return [:]
        }
    }
}

/// The server's side of one call.
final class FakeCall {
    let index: Int
    let metadata: Metadata
    private var requests: RPCAsyncSequence<RecognizeRequest, any Error>.AsyncIterator
    private let writer: RPCWriter<RecognizeResponse>
    private let recorder: CallRecorder
    private(set) var audioSamples = 0

    init(
        index: Int, metadata: Metadata, requests: RPCAsyncSequence<RecognizeRequest, any Error>,
        writer: RPCWriter<RecognizeResponse>, recorder: CallRecorder
    ) {
        self.index = index
        self.metadata = metadata
        self.requests = requests.makeAsyncIterator()
        self.writer = writer
        self.recorder = recorder
    }

    var authorization: String? { metadata[stringValues: "authorization"].first(where: { _ in true }) }

    /// Reads the next request, or nil once the client half-closes.
    func nextRequest() async throws -> RecognizeRequest? {
        guard let request = try await requests.next() else { return nil }
        if case .audio(let audio) = request.streamingRequest {
            audioSamples += audio.count / 2
        }
        await recorder.record(request, call: index)
        return request
    }

    /// Reads until at least `seconds` of audio arrived on this call.
    func waitForAudio(seconds: Double) async throws {
        let target = Int(seconds * Double(AudioChunk.sampleRate))
        while audioSamples < target {
            guard try await nextRequest() != nil else { return }
        }
    }

    /// Reads everything until the client half-closes or goes away.
    func drain() async {
        while (try? await nextRequest()) != nil {}
    }

    func respond(_ response: RecognizeResponse) async throws {
        try await writer.write(response)
    }
}

actor ScriptQueue {
    private var scripts: [CallScript]
    private let fallback: CallScript

    init(_ scripts: [CallScript], fallback: @escaping CallScript = { await $0.drain() }) {
        self.scripts = scripts
        self.fallback = fallback
    }

    func next() -> CallScript {
        scripts.isEmpty ? fallback : scripts.removeFirst()
    }
}

actor CallRecorder {
    struct Call {
        var metadata: Metadata
        var requests: [RecognizeRequest] = []

        var config: RecognizeRequest? { requests.first }

        var audioRequests: [Data] {
            requests.compactMap {
                if case .audio(let audio) = $0.streamingRequest { audio } else { nil }
            }
        }

        var samples: [Int16] {
            audioRequests.reduce(into: Data(), +=).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        }
    }

    private(set) var calls: [Call] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func startCall(metadata: Metadata) -> Int {
        calls.append(Call(metadata: metadata))
        let ready = waiters.filter { $0.count <= calls.count }
        waiters.removeAll { $0.count <= calls.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
        return calls.count - 1
    }

    /// Returns once the server has seen `count` calls. The client sets up a call
    /// before the server sees it, so audio sent after this goes out live on it.
    func waitForCalls(_ count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func record(_ request: RecognizeRequest, call: Int) {
        calls[call].requests.append(request)
    }
}

/// Runs `body` against a provider wired to the fake service through an in-process
/// transport.
func withFakeSpeech(
    scripts: [CallScript],
    fallback: @escaping CallScript = { await $0.drain() },
    settings: SpeechSettings = .forTests(),
    tokens: any AccessTokenProvider = FakeTokens(),
    tuning: StreamTuning? = nil,
    body: (GoogleSpeechProvider, CallRecorder) async throws -> Void
) async throws {
    let transport = InProcessTransport()
    let recorder = CallRecorder()
    let service = FakeSpeechService(scripts: ScriptQueue(scripts, fallback: fallback), recorder: recorder)
    let tuning = tuning ?? .forTests(settings: settings)

    try await withGRPCServer(transport: transport.server, services: [service]) { _ in
        try await withThrowingDiscardingTaskGroup { group in
            let client = GRPCClient(transport: transport.client)
            // Ignores the error runConnections throws when a test makes no call and
            // shuts the client down before it started.
            group.addTask { try? await client.runConnections() }
            defer { client.beginGracefulShutdown() }
            let provider = try GoogleSpeechProvider(
                settings: settings,
                tokenProvider: tokens,
                client: Google_Cloud_Speech_V2_Speech.Client(wrapping: client),
                tuning: tuning)
            try await body(provider, recorder)
        }
    }
}

actor FakeTokens: AccessTokenProvider {
    nonisolated let quotaProjectID: String?
    private var token: String
    private let refreshed: String
    private(set) var refreshes = 0

    init(token: String = "token-1", refreshed: String = "token-2", quotaProjectID: String? = "quota-project") {
        self.token = token
        self.refreshed = refreshed
        self.quotaProjectID = quotaProjectID
    }

    func accessToken() -> String { token }

    func refreshAccessToken() -> String {
        refreshes += 1
        token = refreshed
        return token
    }
}

extension StreamTuning {
    /// Short backoffs so retry tests run in milliseconds.
    static func forTests(settings: SpeechSettings = .forTests()) -> StreamTuning {
        var tuning = StreamTuning(settings: settings)
        tuning.firstBackoff = .milliseconds(5)
        tuning.maxBackoff = .milliseconds(20)
        tuning.finishTimeout = .seconds(5)
        return tuning
    }

    func with(_ change: (inout StreamTuning) -> Void) -> StreamTuning {
        var tuning = self
        change(&tuning)
        return tuning
    }
}

extension SpeechSettings {
    static func forTests(rotateAfterSeconds: Double = 240) -> SpeechSettings {
        var settings = SpeechSettings()
        settings.googleProjectID = "test-project"
        settings.rotateAfterSeconds = rotateAfterSeconds
        return settings
    }
}
