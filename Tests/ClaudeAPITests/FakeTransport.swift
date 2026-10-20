import ClaudeAPI
import Foundation
import Synchronization

/// Replays scripted responses, one per request, and records what was sent.
final class FakeTransport: HTTPStreamingTransport {
    enum Reply: Sendable {
        /// Headers, then these body lines, then the end of the body (or `failure`).
        case response(status: Int, headers: [String: String] = [:], lines: [String], failure: (any Error)? = nil)
        /// These body lines, then nothing until the reader goes away.
        case openStream(lines: [String])
        /// The connection fails before any response.
        case connectionFailure(any Error)
        /// No response ever arrives; only cancellation ends the wait.
        case hang
    }

    private struct State {
        var replies: [Reply]
        var requests: [HTTPRequest] = []
        var cancelledSends = 0
    }

    private let state: Mutex<State>
    /// Yields once for each open body stream that ended because its reader stopped.
    let streamTerminations: AsyncStream<Void>
    private let terminationContinuation: AsyncStream<Void>.Continuation

    init(_ replies: [Reply]) {
        state = Mutex(State(replies: replies))
        (streamTerminations, terminationContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    var requests: [HTTPRequest] { state.withLock { $0.requests } }
    var cancelledSends: Int { state.withLock { $0.cancelledSends } }

    func send(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let reply = state.withLock { state -> Reply? in
            state.requests.append(request)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        guard let reply else {
            throw FakeTransportError.noReplyLeft
        }
        switch reply {
        case .response(let status, let headers, let lines, let failure):
            let (body, continuation) = AsyncThrowingStream.makeStream(of: String.self, throwing: (any Error).self)
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish(throwing: failure)
            return HTTPStreamingResponse(statusCode: status, headers: headers, lines: body)
        case .openStream(let lines):
            let (body, continuation) = AsyncThrowingStream.makeStream(of: String.self, throwing: (any Error).self)
            for line in lines {
                continuation.yield(line)
            }
            let terminations = terminationContinuation
            continuation.onTermination = { _ in terminations.yield() }
            return HTTPStreamingResponse(statusCode: 200, headers: [:], lines: body)
        case .connectionFailure(let error):
            throw error
        case .hang:
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                state.withLock { $0.cancelledSends += 1 }
                throw error
            }
            throw FakeTransportError.noReplyLeft
        }
    }
}

enum FakeTransportError: Error {
    case noReplyLeft
    case connectionReset
}

/// Server-sent event lines as the API writes them, blank separator lines included.
enum SSE {
    static func event(_ json: String) -> [String] {
        let type = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["type"] as? String
        return ["event: \(type ?? "unknown")", "data: \(json)", ""]
    }

    static func messageStart(input: Int = 10, cacheRead: Int = 0, cacheWrite: Int = 0) -> [String] {
        event(
            #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheWrite),"cache_read_input_tokens":\#(cacheRead),"output_tokens":1}}}"#
        )
    }

    static func textBlockStart(index: Int = 0) -> [String] {
        event(#"{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#)
    }

    static func text(_ text: String, index: Int = 0) -> [String] {
        let quoted = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return event(
            #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":\#(quoted)}}"#)
    }

    static func blockStop(index: Int = 0) -> [String] {
        event(#"{"type":"content_block_stop","index":\#(index)}"#)
    }

    static func messageDelta(stopReason: String = "end_turn", output: Int = 5) -> [String] {
        event(
            #"{"type":"message_delta","delta":{"stop_reason":"\#(stopReason)","stop_sequence":null},"usage":{"output_tokens":\#(output)}}"#
        )
    }

    static let ping = event(#"{"type":"ping"}"#)
    static let messageStop = event(#"{"type":"message_stop"}"#)

    static func error(type: String, message: String) -> [String] {
        event(#"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#)
    }

    /// A complete response that streams `parts` as text.
    static func answer(_ parts: [String], output: Int = 5) -> [String] {
        var lines = messageStart() + textBlockStart()
        for part in parts {
            lines += text(part)
        }
        return lines + blockStop() + messageDelta(output: output) + messageStop
    }
}
