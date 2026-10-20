import Testing

@testable import ListenerCore

struct CostTrackerTests {
    func isClose(_ value: Double, _ expected: Double) -> Bool {
        abs(value - expected) < 1e-12
    }

    @Test func haikuAppliesEveryRate() {
        var tracker = CostTracker(prices: .standard, speechProvider: "google")
        let usage = TokenUsage(
            inputTokens: 1_000, outputTokens: 200, cacheReadInputTokens: 5_000, cacheCreationInputTokens: 800)
        // 1000 x 0.10 + 200 x 0.50 + 5000 x 0.01 + 800 x 0.125 = 350 dollars per million tokens
        #expect(isClose(tracker.addModelUsage(usage, model: "claude-haiku-5-5"), 0.000_35))
    }

    @Test func longPromptRatesApplyToTheWholeRequest() {
        let tracker = CostTracker(prices: .standard, speechProvider: "google")
        // 110k prompt tokens, cached ones included, is over Haiku's 100k threshold:
        // 50000 x 0.50 + 60000 x 0.05 + 1000 x 2.50 = 30500 dollars per million tokens
        let long = TokenUsage(inputTokens: 50_000, outputTokens: 1_000, cacheReadInputTokens: 60_000)
        #expect(isClose(tracker.cost(of: long, model: "claude-haiku-5-5"), 0.0305))
    }

    @Test func thresholdItselfStillGetsTheNormalRates() {
        let tracker = CostTracker(prices: .standard, speechProvider: "google")
        let atThreshold = TokenUsage(inputTokens: 100_000)
        let justOver = TokenUsage(inputTokens: 100_001)
        #expect(isClose(tracker.cost(of: atThreshold, model: "claude-haiku-5-5"), 0.01))
        #expect(isClose(tracker.cost(of: justOver, model: "claude-haiku-5-5"), 0.050_000_5))
    }

    @Test func sonnetHasNoLongPromptRates() {
        let tracker = CostTracker(prices: .standard, speechProvider: "google")
        // 1000 x 2.00 + 5000 x 0.20 + 400 x 10.00 = 7000; then 200000 x 2.00 = 400000
        let cached = TokenUsage(inputTokens: 1_000, outputTokens: 400, cacheReadInputTokens: 5_000)
        #expect(isClose(tracker.cost(of: cached, model: "claude-sonnet-5-5"), 0.007))
        #expect(isClose(tracker.cost(of: TokenUsage(inputTokens: 200_000), model: "claude-sonnet-5-5"), 0.4))
    }

    @Test func missingLongRatesFallBackToNormalRates() {
        let price = ModelPrice(
            input: 1, output: 2, cacheRead: 0.1, cacheWrite: 1.25, longPromptThreshold: 10, longPromptInput: 3)
        let usage = TokenUsage(inputTokens: 20, outputTokens: 10)
        // 20 x 3 (long input) + 10 x 2 (no long output rate) = 80
        #expect(isClose(price.cost(of: usage), 0.000_08))
    }

    @Test func unknownModelIsRecordedAtZeroCost() {
        var tracker = CostTracker(prices: .standard, speechProvider: "google")
        #expect(tracker.addModelUsage(TokenUsage(inputTokens: 500, outputTokens: 50), model: "claude-unknown") == 0)
        #expect(tracker.summary.modelUsage["claude-unknown"] == TokenUsage(inputTokens: 500, outputTokens: 50))
        #expect(tracker.summary.modelCost == 0)
    }

    @Test func summaryAccumulatesSpeechAndModelsSeparately() {
        var tracker = CostTracker(prices: .standard, speechProvider: "google")
        tracker.addSpeech(seconds: 90, speaker: .them)
        tracker.addSpeech(seconds: 30, speaker: .me)
        tracker.addSpeech(seconds: 30, speaker: .them)
        tracker.addModelUsage(TokenUsage(inputTokens: 6_000, outputTokens: 150), model: "claude-haiku-5-5")
        tracker.addModelUsage(TokenUsage(inputTokens: 1_000, cacheReadInputTokens: 5_000), model: "claude-haiku-5-5")
        tracker.addModelUsage(TokenUsage(inputTokens: 6_000, outputTokens: 400), model: "claude-sonnet-5-5")

        let summary = tracker.summary
        #expect(summary.speechSeconds == ["Them": 120, "Me": 30])
        // 150 s at 0.016 per minute
        #expect(isClose(summary.speechCost, 0.04))
        #expect(
            summary.modelUsage["claude-haiku-5-5"]
                == TokenUsage(inputTokens: 7_000, outputTokens: 150, cacheReadInputTokens: 5_000))
        // Haiku: 600 + 75 = 675, then 100 + 50 = 150. Sonnet: 12000 + 4000 = 16000.
        #expect(isClose(summary.modelCost, 0.016_825))
        #expect(isClose(summary.total, 0.056_825))
    }

    @Test func fakeSpeechProviderIsFree() {
        var tracker = CostTracker(prices: .standard, speechProvider: "fake")
        tracker.addSpeech(seconds: 600, speaker: .them)
        #expect(tracker.summary.speechCost == 0)
        #expect(tracker.summary.speechSeconds["Them"] == 600)
    }
}
