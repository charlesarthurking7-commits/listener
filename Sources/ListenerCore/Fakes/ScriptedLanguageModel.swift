import Synchronization

/// A language model that answers from a closure, streamed word by word with realistic
/// pacing, for replay demos and tests. It records every request it gets.
public final class ScriptedLanguageModel: LanguageModelProvider, Sendable {
    /// Builds the reply to a request. Throwing makes the stream fail with that error
    /// once the first-token delay has passed.
    public typealias Reply = @Sendable (ModelRequest) throws -> String

    public let firstTokenDelay: Duration
    public let tokenInterval: Duration
    /// Reported in the final event. Nil estimates it from the text: about four
    /// characters per input token and one output token per word.
    public let usage: TokenUsage?
    private let reply: Reply
    private let state = Mutex(State())

    private struct State {
        var requests: [ModelRequest] = []
        var warmUps = 0
        var finished = 0
        var cancelled = 0
    }

    public init(
        firstTokenDelay: Duration = .milliseconds(150),
        tokenInterval: Duration = .milliseconds(15),
        usage: TokenUsage? = nil,
        reply: @escaping Reply
    ) {
        self.firstTokenDelay = firstTokenDelay
        self.tokenInterval = tokenInterval
        self.usage = usage
        self.reply = reply
    }

    /// Always gives the same answer.
    public convenience init(
        answer: String, firstTokenDelay: Duration = .milliseconds(150), tokenInterval: Duration = .milliseconds(15),
        usage: TokenUsage? = nil
    ) {
        self.init(firstTokenDelay: firstTokenDelay, tokenInterval: tokenInterval, usage: usage) { _ in answer }
    }

    /// Every request so far, oldest first.
    public var requests: [ModelRequest] { state.withLock { $0.requests } }
    public var warmUpCount: Int { state.withLock { $0.warmUps } }
    /// Streams that ran to their final event.
    public var finishedCount: Int { state.withLock { $0.finished } }
    /// Streams the consumer abandoned before they finished.
    public var cancelledCount: Int { state.withLock { $0.cancelled } }

    public func warmUp() async {
        state.withLock { $0.warmUps += 1 }
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        state.withLock { $0.requests.append(request) }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ModelEvent.self)
        let task = Task { [self] in
            do {
                try await Task.sleep(for: firstTokenDelay)
                let text = try reply(request)
                let tokens = Self.tokens(of: text)
                for (index, token) in tokens.enumerated() {
                    if index > 0 {
                        try await Task.sleep(for: tokenInterval)
                    }
                    continuation.yield(.text(token))
                }
                let usage = usage ?? Self.estimatedUsage(request: request, outputTokens: tokens.count)
                continuation.yield(.finished(usage, stopReason: "end_turn"))
                continuation.finish()
                state.withLock { $0.finished += 1 }
            } catch is CancellationError {
                state.withLock { $0.cancelled += 1 }
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                task.cancel()
            }
        }
        return stream
    }

    /// Splits text into words that keep their trailing whitespace, so joining the
    /// tokens gives back the text exactly.
    static func tokens(of text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            if !character.isWhitespace && current.last?.isWhitespace == true {
                tokens.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func estimatedUsage(request: ModelRequest, outputTokens: Int) -> TokenUsage {
        let characters = request.system.count + request.user.reduce(0) { $0 + $1.text.count }
        return TokenUsage(inputTokens: max(1, characters / 4), outputTokens: outputTokens)
    }
}
