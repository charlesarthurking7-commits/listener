import Foundation
import ListenerCore

/// The JSON body of POST /v1/messages for one streamed, single-turn request.
struct MessagesRequest: Encodable, Equatable {
    struct TextBlock: Encodable, Equatable {
        var type = "text"
        var text: String
        var cacheControl: CacheControl?

        enum CodingKeys: String, CodingKey {
            case type, text
            case cacheControl = "cache_control"
        }
    }

    struct CacheControl: Encodable, Equatable {
        var type = "ephemeral"
    }

    struct Message: Encodable, Equatable {
        var role: String
        var content: [TextBlock]
    }

    struct Thinking: Encodable, Equatable {
        var type: String
    }

    struct OutputConfig: Encodable, Equatable {
        var effort: String
    }

    var model: String
    var maxTokens: Int
    var stream = true
    var system: [TextBlock]?
    var messages: [Message]
    var thinking: Thinking?
    var outputConfig: OutputConfig?
    /// Server-side fallback when the model declines: "default" lets the API pick the
    /// fallback model by refusal category. Needs `ModelProfile.fallbackBetaHeader`.
    var fallbacks: String?

    enum CodingKeys: String, CodingKey {
        case model, stream, system, messages, thinking, fallbacks
        case maxTokens = "max_tokens"
        case outputConfig = "output_config"
    }

    init(_ request: ModelRequest) {
        let settings = request.settings
        let profile = ModelProfile(model: settings.model)
        let thinking = profile.thinking(settings.thinking, effort: settings.effort)

        model = settings.model
        maxTokens = settings.maxTokens
        if !request.system.isEmpty {
            system = [TextBlock(text: request.system, cacheControl: request.cacheSystem ? CacheControl() : nil)]
        }
        // The API rejects empty and whitespace-only text blocks.
        let content = request.user
            .filter { !$0.text.allSatisfy(\.isWhitespace) }
            .map { TextBlock(text: $0.text, cacheControl: $0.cacheBreakpoint ? CacheControl() : nil) }
        messages = [Message(role: "user", content: content)]
        self.thinking = thinking.map { Thinking(type: $0.rawValue) }
        if !settings.effort.isEmpty {
            outputConfig = OutputConfig(effort: settings.effort)
        }
        if profile.usesServerSideFallback(thinking: thinking) {
            fallbacks = "default"
        }
    }

    var usesServerSideFallback: Bool { fallbacks != nil }
}

/// What a model accepts, where models differ in ways the request has to respect.
struct ModelProfile: Equatable {
    enum ThinkingType: String {
        case adaptive
        case disabled
        case betweenTools = "between_tools"
    }

    enum ThinkingOff: Equatable {
        /// `{"type": "disabled"}`, accepted at effort high or below.
        case disabled
        /// Sonnet 5.5 rejects "disabled"; `between_tools` is its lowest setting, also
        /// only at effort high or below.
        case betweenTools
        /// Opus 5.5 always thinks. Omit the field and let effort set the depth.
        case unsupported
    }

    static let fallbackBetaHeader = "server-side-fallback-2026-07-01"

    var thinkingOff: ThinkingOff
    /// Only Sonnet 5.5 and Opus 5.5 offer server-side fallback; Haiku 5.5 rejects it.
    var supportsServerSideFallback: Bool

    init(model: String) {
        if model.hasPrefix("claude-sonnet-5-5") {
            thinkingOff = .betweenTools
            supportsServerSideFallback = true
        } else if model.hasPrefix("claude-opus-5-5") {
            thinkingOff = .unsupported
            supportsServerSideFallback = true
        } else {
            thinkingOff = .disabled
            supportsServerSideFallback = false
        }
    }

    /// The `thinking.type` to send, or nil to leave the field out.
    func thinking(_ mode: ThinkingMode, effort: String) -> ThinkingType? {
        switch mode {
        case .adaptive:
            return .adaptive
        case .off:
            // Neither "disabled" nor "between_tools" is allowed above effort high, so
            // thinking stays on there rather than failing the request.
            if effort == "xhigh" || effort == "max" {
                return .adaptive
            }
            switch thinkingOff {
            case .disabled: return .disabled
            case .betweenTools: return .betweenTools
            case .unsupported: return nil
            }
        }
    }

    /// Fallback is sent whenever the model thinks adaptively, which includes Opus 5.5
    /// with the field left out. Never with `between_tools`.
    func usesServerSideFallback(thinking: ThinkingType?) -> Bool {
        supportsServerSideFallback && (thinking == .adaptive || thinking == nil)
    }
}
