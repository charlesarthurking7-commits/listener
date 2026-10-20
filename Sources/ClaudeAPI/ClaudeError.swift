import Foundation

/// Why a request to the Anthropic API failed. `errorDescription` is written to be
/// shown to the user as is.
public enum ClaudeError: Error, Equatable, Sendable {
    /// 401: the API key is missing, wrong or revoked.
    case authentication
    /// 403, or 402 for billing: the key works but may not do this.
    case permission(String)
    /// 400, 404 or 413, with the API's own explanation.
    case invalidRequest(String)
    /// 429. `retryAfter` is in seconds, when the API said.
    case rateLimited(retryAfter: Double?)
    /// 529, or an `overloaded_error` in the middle of a stream.
    case overloaded
    /// 5xx or an `api_error` event.
    case server(status: Int?, message: String?)
    /// The model declined to answer (`stop_reason: "refusal"`). Any text already
    /// streamed is incomplete and should be discarded.
    case refused(category: String?)
    /// No usable response: DNS, TLS, timeout, dropped connection or a malformed stream.
    case network(String)

    /// Maps an error response or an `error` stream event. `status` is nil for stream
    /// events, which arrive after a 200.
    static func from(status: Int?, type: String?, message: String?, retryAfter: Double? = nil) -> ClaudeError {
        let text = message ?? "no details given"
        switch (status, type) {
        case (401, _), (_, "authentication_error"):
            return .authentication
        case (402, _), (403, _), (_, "permission_error"), (_, "billing_error"):
            return .permission(text)
        case (429, _), (_, "rate_limit_error"):
            return .rateLimited(retryAfter: retryAfter)
        case (529, _), (_, "overloaded_error"):
            return .overloaded
        case (400, _), (404, _), (413, _), (_, "invalid_request_error"), (_, "not_found_error"),
            (_, "request_too_large"):
            return .invalidRequest(text)
        default:
            return .server(status: status, message: message)
        }
    }
}

extension ClaudeError: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? {
        switch self {
        case .authentication:
            "The Anthropic API key was rejected. Check the key in the Keychain or ANTHROPIC_API_KEY."
        case .permission(let message):
            "The Anthropic account cannot make this request: \(message)"
        case .invalidRequest(let message):
            "The Anthropic API rejected the request: \(message)"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                "Rate limited by the Anthropic API. Try again in \(Int(retryAfter.rounded(.up))) s."
            } else {
                "Rate limited by the Anthropic API. Try again shortly."
            }
        case .overloaded:
            "The Anthropic API is overloaded right now. Try again in a moment."
        case .server(let status, _):
            if let status {
                "The Anthropic API had an internal error (HTTP \(status)). Try again."
            } else {
                "The Anthropic API had an internal error. Try again."
            }
        case .refused(let category):
            if let category {
                "Claude declined to answer this one (policy category: \(category))."
            } else {
                "Claude declined to answer this one."
            }
        case .network(let detail):
            "Could not reach the Anthropic API: \(detail)"
        }
    }

    public var description: String { errorDescription ?? "Anthropic API error" }
}
