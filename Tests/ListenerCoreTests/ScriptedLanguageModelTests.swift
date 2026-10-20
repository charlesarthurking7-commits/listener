import Testing

@testable import ListenerCore

struct ScriptedLanguageModelTests {
    private let request = ModelRequest(
        settings: AnswerSettings().quick, system: "Be brief.", user: [PromptBlock("Them: How are the fills?")])

    private func collect(_ stream: AsyncThrowingStream<ModelEvent, any Error>) async throws -> [ModelEvent] {
        var events: [ModelEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    @Test func streamsTheReplyWordByWordThenUsage() async throws {
        let usage = TokenUsage(inputTokens: 120, outputTokens: 7)
        let model = ScriptedLanguageModel(firstTokenDelay: .zero, tokenInterval: .zero, usage: usage) { request in
            "Fills look fine,\nall within\ttolerance. (\(request.user.count) block)"
        }
        let events = try await collect(model.stream(request))
        let texts = events.compactMap { event -> String? in
            if case .text(let text) = event { return text }
            return nil
        }
        #expect(texts == ["Fills ", "look ", "fine,\n", "all ", "within\t", "tolerance. ", "(1 ", "block)"])
        #expect(events.last == .finished(usage, stopReason: "end_turn"))
        #expect(model.requests == [request])
    }

    @Test func estimatesUsageWhenNoneIsGiven() async throws {
        let model = ScriptedLanguageModel(answer: "one two three", firstTokenDelay: .zero, tokenInterval: .zero)
        let events = try await collect(model.stream(request))
        // 9 + 24 characters of prompt.
        #expect(events.last == .finished(TokenUsage(inputTokens: 8, outputTokens: 3), stopReason: "end_turn"))
    }

    @Test func waitsForTheFirstTokenAndPacesTheRest() async throws {
        let model = ScriptedLanguageModel(
            answer: "a b c", firstTokenDelay: .milliseconds(120), tokenInterval: .milliseconds(40))
        let started = ContinuousClock.now
        var arrivals: [Double] = []
        for try await event in model.stream(request) {
            if case .text = event {
                arrivals.append((ContinuousClock.now - started).inSeconds)
            }
        }
        #expect(arrivals.count == 3)
        #expect(arrivals[0] >= 0.12)
        // Two 40 ms gaps; a first token picked up late on a busy machine shortens the span.
        #expect(arrivals[2] - arrivals[0] >= 0.06)
    }

    @Test func abandoningTheStreamCancelsGeneration() async throws {
        let model = ScriptedLanguageModel(
            answer: String(repeating: "word ", count: 200), firstTokenDelay: .zero, tokenInterval: .milliseconds(10))
        let consumer = Task {
            var count = 0
            for try await _ in model.stream(request) {
                count += 1
            }
            return count
        }
        try await Task.sleep(for: .milliseconds(60))
        consumer.cancel()
        let received = try await consumer.value
        #expect(received < 200)
        let deadline = ContinuousClock.now + .seconds(1)
        while model.cancelledCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.cancelledCount == 1)
    }

    @Test func aThrowingReplyFailsTheStream() async {
        struct Overloaded: Error {}
        let model = ScriptedLanguageModel(firstTokenDelay: .zero) { _ in throw Overloaded() }
        await #expect(throws: Overloaded.self) {
            _ = try await collect(model.stream(request))
        }
    }

    @Test func countsWarmUps() async {
        let model = ScriptedLanguageModel(answer: "")
        await model.warmUp()
        await model.warmUp()
        #expect(model.warmUpCount == 2)
    }

    @Test func tokensJoinBackToTheText() {
        for text in ["", " leading", "trailing  ", "a  b\n\nc", "single"] {
            #expect(ScriptedLanguageModel.tokens(of: text).joined() == text)
        }
        #expect(ScriptedLanguageModel.tokens(of: " leading") == [" ", "leading"])
    }
}
