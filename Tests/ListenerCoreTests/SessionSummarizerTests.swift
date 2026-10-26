import Foundation
import Testing

@testable import ListenerCore

struct SessionSummarizerTests {
    @Test func summarisesASavedSessionAndAddsItsCost() async throws {
        let root = try temporaryDirectory("summary")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root, startedAt: Date(timeIntervalSince1970: 1_790_000_000))
        try store.append(Turn(id: 1, speaker: .them, text: "Can you send the report?", start: 1, end: 2))
        try store.append(Turn(id: 2, speaker: .me, text: "Yes, today.", start: 3, end: 4))
        let record = SessionRecord(
            startedAt: Date(timeIntervalSince1970: 1_790_000_000), channels: [], speechProvider: "x",
            settings: Settings(), turnCount: 2, cost: CostSummary(speechCost: 0.1))
        try store.write(record)
        try store.close()

        let model = tradeModel(firstTokenDelay: .zero, tokenInterval: .zero)
        let url = try await SessionSummarizer.summarize(directory: store.directory, settings: Settings(), model: model)

        #expect(url.lastPathComponent == "summary.md")
        #expect(try String(contentsOf: url, encoding: .utf8) == tradeSummary + "\n")
        let request = try #require(model.requests.first)
        #expect(request.settings == SummarySettings().model)
        #expect(request.userText.contains("Them: Can you send the report?"))
        #expect(request.userText.contains("Me: Yes, today."))
        // Titled with the saved session's start, not the time it was summarised.
        #expect(request.userText.contains("21 September 2026"))

        let updated = try SessionStore.readRecord(in: store.directory)
        #expect(updated.summaryFile == "summary.md")
        #expect(updated.cost.speechCost == 0.1)
        #expect(updated.cost.modelUsage["claude-sonnet-5-5"] == TokenUsage(inputTokens: 1_200, outputTokens: 40))
        #expect(updated.cost.modelCost > 0)
    }

    @Test func refusesAnEmptyTranscriptOrSummary() async throws {
        let root = try temporaryDirectory("summary")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        try store.close()
        let model = ScriptedLanguageModel(answer: "  ", firstTokenDelay: .zero, tokenInterval: .zero)
        await #expect(throws: SessionSummarizerError.emptyTranscript) {
            try await SessionSummarizer.summarize(directory: store.directory, settings: Settings(), model: model)
        }
        await #expect(throws: SessionSummarizerError.emptySummary) {
            let turns = [Turn(id: 1, speaker: .me, text: "Hello", start: 0, end: 1)]
            _ = try await SessionSummarizer.generate(turns: turns, settings: Settings(), model: model)
        }
        #expect(model.requests.count == 1)
    }

    @Test func aSummaryCutOffAtTheTokenLimitSaysSo() async throws {
        let model = ScriptedLanguageModel(
            answer: "## Summary\n\nThe report", firstTokenDelay: .zero, tokenInterval: .zero, stopReason: "max_tokens")
        let turns = [Turn(id: 1, speaker: .them, text: "Can you send the report?", start: 0, end: 2)]
        let summary = try await SessionSummarizer.generate(turns: turns, settings: Settings(), model: model)
        #expect(summary.cutShort)
        #expect(summary.markdown.hasPrefix("## Summary\n\nThe report\n\n"))
        #expect(summary.markdown.hasSuffix(SessionSummarizer.cutShortNote))
    }
}
