import Foundation
import ListenerCore
import Synchronization

/// The Anthropic Messages API over HTTPS, streamed with server-sent events.
///
/// One client is shared by every answer in the app. It keeps no per-request state,
/// so concurrent streams are fine; the transport decides how connections are reused.
public final class ClaudeClient: LanguageModelProvider {
    public struct Timing: Sendable {
        /// How long to wait for the response headers. A streamed response sends them
        /// straight away, so a longer wait means a dead connection worth one retry.
        public var responseTimeout: Duration
        /// Pause before the single retry. Short, because someone is waiting for the answer.
        public var retryDelay: Duration
        /// A 429 that asks for a longer wait than this fails at once instead.
        public var maxRetryAfter: Duration
        /// `warmUp()` does nothing when it last ran less than this long ago.
        public var warmUpInterval: Duration

        public static let standard = Timing(
            responseTimeout: .seconds(10), retryDelay: .milliseconds(250), maxRetryAfter: .seconds(2),
            warmUpInterval: .seconds(60))
    }

    static let baseURL = URL(string: "https://api.anthropic.com")!
    static let apiVersion = "2023-06-01"

    private let apiKey: String
    private let transport: any HTTPStreamingTransport
    private let timing: Timing
    private let lastWarmUp = Mutex<ContinuousClock.Instant?>(nil)

    public init(apiKey: String, transport: any HTTPStreamingTransport, timing: Timing = .standard) {
        self.apiKey = apiKey
        self.transport = transport
        self.timing = timing
    }

    /// Streams the answer's text, then `.finished` with the usage. Fails with a
    /// `ClaudeError`, or `CancellationError` once the consumer has gone away.
    /// Cancelling the task that iterates the stream cancels the HTTP request.
    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ModelEvent.self, throwing: (any Error).self)
        let task = Task {
            do {
                try await run(request, continuation: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Opens the connection with a tiny authenticated GET so the first answer skips
    /// DNS and the TLS handshake. Errors are ignored: the real request reports them.
    public func warmUp() async {
        let now = ContinuousClock.now
        let interval = timing.warmUpInterval
        let isDue = lastWarmUp.withLock { lastRun in
            if let previous = lastRun, now - previous < interval {
                return false
            }
            lastRun = now
            return true
        }
        guard isDue else {
            return
        }
        let url = Self.baseURL.appending(path: "v1/models")
            .appending(queryItems: [URLQueryItem(name: "limit", value: "1")])
        let request = HTTPRequest(method: "GET", url: url, headers: commonHeaders)
        if let response = try? await send(request) {
            _ = try? await response.readBody()
        }
    }

    func httpRequest(for request: ModelRequest) throws -> HTTPRequest {
        let body = MessagesRequest(request)
        var headers = commonHeaders
        headers["content-type"] = "application/json"
        if body.usesServerSideFallback {
            headers["anthropic-beta"] = ModelProfile.fallbackBetaHeader
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return HTTPRequest(
            method: "POST", url: Self.baseURL.appending(path: "v1/messages"), headers: headers,
            body: try encoder.encode(body))
    }

    private var commonHeaders: [String: String] {
        ["x-api-key": apiKey, "anthropic-version": Self.apiVersion]
    }

    private func run(
        _ request: ModelRequest, continuation: AsyncThrowingStream<ModelEvent, any Error>.Continuation
    ) async throws {
        let httpRequest = try httpRequest(for: request)
        var hasRetried = false
        while true {
            var hasSentText = false
            do {
                try await attempt(httpRequest) { event in
                    if case .text = event {
                        hasSentText = true
                    }
                    continuation.yield(event)
                }
                return
            } catch let error as ClaudeError {
                // Once text is on screen a retry would repeat or contradict it.
                guard !hasRetried, !hasSentText, let delay = retryDelay(after: error) else {
                    throw error
                }
                hasRetried = true
                try await Task.sleep(for: delay)
            }
        }
    }

    private func attempt(_ request: HTTPRequest, emit: (ModelEvent) -> Void) async throws {
        let response = try await send(request)
        guard response.statusCode == 200 else {
            throw await apiError(from: response)
        }
        var parser = MessageStreamParser()
        do {
            for try await line in response.lines {
                if let event = try parser.consume(line) {
                    emit(event)
                }
                if parser.isFinished {
                    break
                }
            }
        } catch let error as ClaudeError {
            throw error
        } catch {
            throw connectionError(error)
        }
        try Task.checkCancellation()
        try parser.finish()
    }

    /// Sends the request, giving up if the headers take longer than `responseTimeout`.
    private func send(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let transport = transport
        let timeout = timing.responseTimeout
        do {
            return try await withThrowingTaskGroup(of: HTTPStreamingResponse?.self) { group in
                group.addTask {
                    try await transport.send(request)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                let first = try await group.next()
                group.cancelAll()
                guard let response = first ?? nil else {
                    throw ClaudeError.network("timed out waiting for a response")
                }
                return response
            }
        } catch let error as ClaudeError {
            throw error
        } catch {
            throw connectionError(error)
        }
    }

    private func apiError(from response: HTTPStreamingResponse) async -> ClaudeError {
        let body = (try? await response.readBody()) ?? ""
        let details = try? JSONDecoder().decode(ErrorResponse.self, from: Data(body.utf8)).error
        var retryAfter: Double?
        if let header = response.headers["retry-after"], let seconds = Double(header), seconds.isFinite, seconds >= 0 {
            retryAfter = seconds
        }
        return .from(
            status: response.statusCode, type: details?.type, message: details?.message, retryAfter: retryAfter)
    }

    private func connectionError(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled {
            return CancellationError()
        }
        return ClaudeError.network(error.localizedDescription)
    }

    private func retryDelay(after error: ClaudeError) -> Duration? {
        switch error {
        case .rateLimited(let retryAfter):
            guard let retryAfter else {
                return timing.retryDelay
            }
            let wait = Duration.seconds(retryAfter)
            return wait <= timing.maxRetryAfter ? max(wait, timing.retryDelay) : nil
        case .overloaded, .server, .network:
            return timing.retryDelay
        case .authentication, .permission, .invalidRequest, .refused:
            return nil
        }
    }
}
