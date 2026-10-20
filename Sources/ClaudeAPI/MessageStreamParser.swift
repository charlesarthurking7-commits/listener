import Foundation
import ListenerCore

/// Turns the server-sent events of a streamed Messages response into `ModelEvent`s.
///
/// Anthropic sends every event as an `event:` line followed by one `data:` line of
/// JSON that repeats the event type, then a blank line. Blank lines may never reach
/// us (URLSession drops them), so the parser dispatches on each `data:` line alone
/// and ignores everything else.
struct MessageStreamParser {
    private(set) var usage = TokenUsage()
    private(set) var stopReason: String?
    private(set) var isFinished = false
    private var stopCategory: String?
    private let decoder = JSONDecoder()

    /// Feeds one line. Returns the event it produced, if any. Throws `ClaudeError`
    /// for `error` events, refusals and data it cannot read.
    mutating func consume(_ line: String) throws -> ModelEvent? {
        guard !isFinished, line.hasPrefix("data:") else {
            return nil
        }
        var payload = line.utf8.dropFirst(5)
        if payload.first == UInt8(ascii: " ") {
            payload = payload.dropFirst()
        }
        let data = Data(payload)
        let event: StreamEvent
        do {
            event = try decoder.decode(StreamEvent.self, from: data)
        } catch {
            // An event type added after this was written may reuse a field name with
            // another shape. Skip it; only events we act on have to decode.
            if let other = try? decoder.decode(EventType.self, from: data), !Self.handledTypes.contains(other.type) {
                return nil
            }
            throw ClaudeError.network("the response stream could not be read")
        }
        return try handle(event)
    }

    private static let handledTypes: Set = [
        "message_start", "content_block_start", "content_block_delta", "message_delta", "message_stop", "error",
    ]

    private struct EventType: Decodable {
        var type: String
    }

    /// Call when the body has ended. A stream that stops before `message_stop` was
    /// cut off, whatever the reason.
    func finish() throws {
        if !isFinished {
            throw ClaudeError.network("the connection closed before the answer was complete")
        }
    }

    private mutating func handle(_ event: StreamEvent) throws -> ModelEvent? {
        switch event.type {
        case "message_start":
            if let reported = event.message?.usage {
                merge(reported)
            }
        case "content_block_start":
            // Text blocks normally start empty; thinking and fallback blocks are skipped.
            if let block = event.contentBlock, block.type == "text", let text = block.text, !text.isEmpty {
                return .text(text)
            }
        case "content_block_delta":
            if let delta = event.delta, delta.type == "text_delta", let text = delta.text, !text.isEmpty {
                return .text(text)
            }
        case "message_delta":
            if let reason = event.delta?.stopReason {
                stopReason = reason
            }
            if let category = event.delta?.stopDetails?.category {
                stopCategory = category
            }
            if let reported = event.usage {
                merge(reported)
            }
        case "message_stop":
            isFinished = true
            if stopReason == "refusal" {
                throw ClaudeError.refused(category: stopCategory)
            }
            return .finished(usage, stopReason: stopReason)
        case "error":
            throw ClaudeError.from(status: nil, type: event.error?.type, message: event.error?.message)
        default:
            // ping, content_block_stop and event types added after this was written.
            break
        }
        return nil
    }

    /// `message_start` carries the input side; `message_delta` carries cumulative
    /// totals, sometimes only output_tokens. A reported field replaces what we had.
    private mutating func merge(_ reported: StreamEvent.Usage) {
        if let value = reported.inputTokens {
            usage.inputTokens = value
        }
        if let value = reported.outputTokens {
            usage.outputTokens = value
        }
        if let value = reported.cacheReadInputTokens {
            usage.cacheReadInputTokens = value
        }
        if let value = reported.cacheCreationInputTokens {
            usage.cacheCreationInputTokens = value
        }
    }
}

/// The union of the fields we read from any stream event.
struct StreamEvent: Decodable {
    struct Message: Decodable {
        var usage: Usage?
    }

    struct ContentBlock: Decodable {
        var type: String
        var text: String?
    }

    struct Delta: Decodable {
        var type: String?
        var text: String?
        var stopReason: String?
        var stopDetails: StopDetails?

        enum CodingKeys: String, CodingKey {
            case type, text
            case stopReason = "stop_reason"
            case stopDetails = "stop_details"
        }
    }

    struct StopDetails: Decodable {
        var category: String?
    }

    struct Usage: Decodable {
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheReadInputTokens: Int?
        var cacheCreationInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
        }
    }

    struct APIError: Decodable {
        var type: String?
        var message: String?
    }

    var type: String
    var message: Message?
    var contentBlock: ContentBlock?
    var delta: Delta?
    var usage: Usage?
    var error: APIError?

    enum CodingKeys: String, CodingKey {
        case type, message, delta, usage, error
        case contentBlock = "content_block"
    }
}

/// The body of a non-2xx response: `{"type": "error", "error": {"type": ..., "message": ...}}`.
struct ErrorResponse: Decodable {
    var error: StreamEvent.APIError
}
