import Foundation
import ListenerCore

/// The JSON body of POST /v1/messages for one streamed, single-turn request, encoded
/// with snake-case keys.
struct MessagesRequest: Encodable {
    struct TextBlock: Encodable {
        var type = "text"
        var text: String
        var cacheControl: CacheControl?
    }

    struct CacheControl: Encodable {
        var type = "ephemeral"
    }

    struct Message: Encodable {
        var role: String
        var content: [TextBlock]
    }

    struct Thinking: Encodable {
        var type: String
    }

    struct OutputConfig: Encodable {
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
struct ModelProfile {
    enum ThinkingType: String {
        case adaptive
        case disabled
        case betweenTools = "between_tools"
    }

    static let fallbackBetaHeader = "server-side-fallback-2026-07-01"

    /// What turning thinking off sends, or nil to leave the field out.
    var thinkingOff: ThinkingType?
    /// Only Sonnet 5.5 and Opus 5.5 offer server-side fallback; Haiku 5.5 rejects it.
    var supportsServerSideFallback: Bool

    init(model: String) {
        if model.hasPrefix("claude-sonnet-5-5") {
            // Sonnet 5.5 rejects "disabled"; `between_tools` is its lowest setting, also
            // only at effort high or below.
            thinkingOff = .betweenTools
            supportsServerSideFallback = true
        } else if model.hasPrefix("claude-opus-5-5") {
            // Opus 5.5 always thinks. Omit the field and let effort set the depth.
            thinkingOff = nil
            supportsServerSideFallback = true
        } else {
            // `{"type": "disabled"}`, accepted at effort high or below.
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
            return effort == "xhigh" || effort == "max" ? .adaptive : thinkingOff
        }
    }

    /// Fallback is sent whenever the model thinks adaptively, which includes Opus 5.5
    /// with the field left out. Never with `between_tools`.
    func usesServerSideFallback(thinking: ThinkingType?) -> Bool {
        supportsServerSideFallback && (thinking == .adaptive || thinking == nil)
    }
}
