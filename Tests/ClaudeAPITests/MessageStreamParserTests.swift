import ListenerCore
import Testing

@testable import ClaudeAPI

struct MessageStreamParserTests {
    func parse(_ lines: [String]) throws -> [ModelEvent] {
        var parser = MessageStreamParser()
        var events: [ModelEvent] = []
        for line in lines {
            if let event = try parser.consume(line) {
                events.append(event)
            }
        }
        try parser.finish()
        return events
    }

    @Test func emitsTextAndFinalUsage() throws {
        let lines =
            SSE.messageStart(input: 120, cacheRead: 3000, cacheWrite: 400) + SSE.textBlockStart() + SSE.ping
            + SSE.text("Yes, ") + SSE.text("we can.") + SSE.blockStop() + SSE.messageDelta(output: 42) + SSE.messageStop
        let usage = TokenUsage(
            inputTokens: 120, outputTokens: 42, cacheReadInputTokens: 3000, cacheCreationInputTokens: 400)
        #expect(try parse(lines) == [.text("Yes, "), .text("we can."), .finished(usage, stopReason: "end_turn")])
    }

    @Test func dispatchesOnDataLinesAloneWithoutBlankLines() throws {
        let lines = SSE.answer(["Hi"]).filter { $0.hasPrefix("data:") }.map { "data:" + $0.dropFirst(6) }
        #expect(try parse(lines).first == .text("Hi"))
    }

    @Test func skipsThinkingBlocks() throws {
        let lines =
            SSE.messageStart()
            + SSE.event(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#)
            + SSE.event(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#)
            + SSE.event(#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"x"}}"#)
            + SSE.blockStop() + SSE.textBlockStart(index: 1) + SSE.text("Answer", index: 1) + SSE.blockStop(index: 1)
            + SSE.messageDelta() + SSE.messageStop
        let events = try parse(lines)
        #expect(events.count == 2)
        #expect(events.first == .text("Answer"))
    }

    @Test func laterMessageDeltaUsageReplacesEarlierCounts() throws {
        let lines =
            SSE.messageStart(input: 10)
            + SSE.event(
                #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"input_tokens":12,"output_tokens":600}}"#
            ) + SSE.messageStop
        #expect(
            try parse(lines) == [.finished(TokenUsage(inputTokens: 12, outputTokens: 600), stopReason: "max_tokens")])
    }

    @Test func refusalFailsWithItsCategory() {
        let lines =
            SSE.messageStart() + SSE.textBlockStart() + SSE.text("Partial")
            + SSE.event(
                #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":null}},"usage":{"output_tokens":3}}"#
            ) + SSE.messageStop
        #expect(throws: ClaudeError.refused(category: "cyber")) { try parse(lines) }
    }

    @Test func errorEventsMapToTypedErrors() {
        #expect(throws: ClaudeError.overloaded) {
            try parse(SSE.messageStart() + SSE.error(type: "overloaded_error", message: "Overloaded"))
        }
        #expect(throws: ClaudeError.server(status: nil, message: "Internal error")) {
            try parse(SSE.error(type: "api_error", message: "Internal error"))
        }
    }

    @Test func streamThatStopsEarlyIsAnError() {
        #expect(throws: ClaudeError.self) { try parse(SSE.messageStart() + SSE.textBlockStart() + SSE.text("Hal")) }
    }

    @Test func unreadableKnownEventIsAnErrorButUnknownEventsAreSkipped() throws {
        #expect(throws: ClaudeError.self) { try parse(["data: {\"type\":\"content_block_delta\",\"delta\":42}"]) }
        let lines =
            SSE.messageStart() + ["data: {\"type\":\"future_event\",\"delta\":\"surprise\"}"] + SSE.answer(["Ok"])
        #expect(try parse(lines).first == .text("Ok"))
    }

    @Test func ignoresLinesAfterMessageStop() throws {
        let lines = SSE.answer(["Done"]) + SSE.text("extra")
        #expect(try parse(lines).count == 2)
    }

    @Test func handlesEscapesAndUnicodeInText() throws {
        let text = "Line \"one\"\nand £5 \u{1F600}"
        #expect(try parse(SSE.answer([text])).first == .text(text))
    }
}
