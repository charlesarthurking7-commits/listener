/// Running cost of a session. Placeholder: the full version applies cache and
/// long-prompt rates.
public struct CostTracker: Sendable {
    public let prices: PriceTable
    public let speechProvider: String
    public private(set) var summary = CostSummary()

    public init(prices: PriceTable, speechProvider: String) {
        self.prices = prices
        self.speechProvider = speechProvider
    }

    public mutating func addSpeech(seconds: Double, speaker: Speaker) {
        summary.speechSeconds[speaker.rawValue, default: 0] += seconds
        let perMinute = prices.speechPerMinute[speechProvider] ?? 0
        summary.speechCost += seconds / 60 * perMinute
    }

    /// Records one response's usage and returns what that response cost.
    @discardableResult
    public mutating func addModelUsage(_ usage: TokenUsage, model: String) -> Double {
        var total = summary.modelUsage[model] ?? TokenUsage()
        total.inputTokens += usage.inputTokens
        total.outputTokens += usage.outputTokens
        total.cacheReadInputTokens += usage.cacheReadInputTokens
        total.cacheCreationInputTokens += usage.cacheCreationInputTokens
        summary.modelUsage[model] = total

        guard let price = prices.models[model] else {
            return 0
        }
        let cost = (Double(usage.inputTokens) * price.input + Double(usage.outputTokens) * price.output) / 1_000_000
        summary.modelCost += cost
        return cost
    }
}
