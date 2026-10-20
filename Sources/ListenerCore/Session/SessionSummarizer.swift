import Foundation

public enum SessionSummarizerError: Error, Equatable {
    case emptyTranscript
    case emptySummary
}

/// Writes the post-call Markdown summary. CallSession uses it at Stop, and
/// `listener summarize` to (re)summarise a saved session.
public enum SessionSummarizer {
    public struct Summary: Sendable, Equatable {
        public var markdown: String
        public var model: String
        public var usage: TokenUsage?
    }

    /// Streams the summary request for `turns` to the end. `startedAt` and `duration`
    /// (seconds) title the notes; without them the call is taken to have just ended.
    public static func generate(
        turns: [Turn], settings: Settings, model: any LanguageModelProvider, startedAt: Date? = nil,
        duration: Double? = nil
    ) async throws -> Summary {
        guard !turns.isEmpty else {
            throw SessionSummarizerError.emptyTranscript
        }
        let request = PromptBuilder(answers: settings.answers)
            .summaryRequest(turns: turns, settings: settings.summary, startedAt: startedAt, duration: duration)
        var markdown = ""
        var usage: TokenUsage?
        for try await event in model.stream(request) {
            switch event {
            case .text(let text): markdown += text
            case .finished(let finalUsage, _): usage = finalUsage
            }
        }
        try Task.checkCancellation()
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionSummarizerError.emptySummary
        }
        return Summary(markdown: markdown, model: request.settings.model, usage: usage)
    }

    /// Re-reads a saved session's transcript, writes its summary.md and adds the cost to
    /// its session.json. Returns the summary's URL.
    @discardableResult
    public static func summarize(directory: URL, settings: Settings, model: any LanguageModelProvider) async throws
        -> URL
    {
        let saved = try? SessionStore.readRecord(in: directory)
        let summary = try await generate(
            turns: SessionStore.readTurns(in: directory), settings: settings, model: model,
            startedAt: saved?.startedAt ?? SessionStore.startDate(fromDirectoryName: directory.lastPathComponent),
            duration: saved?.duration)
        let url = try SessionStore.writeSummary(summary.markdown, in: directory)

        if var record = saved {
            if let usage = summary.usage {
                var tracker = CostTracker(prices: settings.prices, speechProvider: settings.speech.provider)
                record.cost.modelCost += tracker.addModelUsage(usage, model: summary.model)
                record.cost.modelUsage[summary.model] = sum(
                    record.cost.modelUsage[summary.model] ?? TokenUsage(), usage)
            }
            record.summaryFile = SessionStore.summaryFile
            try SessionStore.encoder(pretty: true).encode(record)
                .write(to: directory.appendingPathComponent(SessionStore.recordFile), options: .atomic)
        }
        return url
    }
}

private func sum(_ lhs: TokenUsage, _ rhs: TokenUsage) -> TokenUsage {
    TokenUsage(
        inputTokens: lhs.inputTokens + rhs.inputTokens,
        outputTokens: lhs.outputTokens + rhs.outputTokens,
        cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens,
        cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens)
}
