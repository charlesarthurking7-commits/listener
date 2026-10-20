/// Which hotkey asked for the answer.
public enum AnswerTier: String, Sendable, Codable, CaseIterable {
    /// Fast model, low effort, no thinking: the default hotkey.
    case quick
    /// Stronger model for harder questions: the escalation hotkey.
    case deep
}

public enum ThinkingMode: String, Sendable, Codable {
    /// No visible-latency thinking. Each provider maps this to whatever the model
    /// accepts (Haiku 5.5: disabled, Sonnet 5.5: between_tools).
    case off
    case adaptive
}

/// One model call's knobs, as configured in settings.
public struct ModelSettings: Sendable, Codable, Equatable {
    public var model: String
    public var effort: String
    public var thinking: ThinkingMode
    public var maxTokens: Int

    public init(model: String, effort: String, thinking: ThinkingMode, maxTokens: Int) {
        self.model = model
        self.effort = effort
        self.thinking = thinking
        self.maxTokens = maxTokens
    }
}

/// A block of the user message. `cacheBreakpoint` asks the provider to cache the
/// prompt up to and including this block.
public struct PromptBlock: Sendable, Equatable {
    public var text: String
    public var cacheBreakpoint: Bool

    public init(_ text: String, cacheBreakpoint: Bool = false) {
        self.text = text
        self.cacheBreakpoint = cacheBreakpoint
    }
}

/// A single-turn request: one system prompt, one user message. Every answer is a
/// fresh request built from the transcript, never a growing conversation.
public struct ModelRequest: Sendable, Equatable {
    public var settings: ModelSettings
    public var system: String
    /// Cache the system prompt too. Only worth it when it is long enough to cache.
    public var cacheSystem: Bool
    public var user: [PromptBlock]

    public init(settings: ModelSettings, system: String, cacheSystem: Bool = false, user: [PromptBlock]) {
        self.settings = settings
        self.system = system
        self.cacheSystem = cacheSystem
        self.user = user
    }
}

public struct TokenUsage: Sendable, Codable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadInputTokens: Int
    public var cacheCreationInputTokens: Int

    public init(
        inputTokens: Int = 0, outputTokens: Int = 0, cacheReadInputTokens: Int = 0, cacheCreationInputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }

    /// Everything the model read, cached or not. Pricing tiers key off this.
    public var promptTokens: Int { inputTokens + cacheReadInputTokens + cacheCreationInputTokens }
}

public enum ModelEvent: Sendable, Equatable {
    /// Visible answer text, in order.
    case text(String)
    /// The last event of a successful stream.
    case finished(TokenUsage, stopReason: String?)
}

public protocol LanguageModelProvider: Sendable {
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error>

    /// Opens the connection ahead of the first request so the first answer doesn't
    /// pay for DNS and the TLS handshake. Safe to call repeatedly.
    func warmUp() async
}
