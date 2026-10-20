/// Running cost of a session: speech-to-text by the minute, model calls by token
/// with cache and long-prompt rates from the price table.
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

    /// Records one response's usage and returns what that response cost. Models
    /// missing from the price table are recorded at zero cost.
    @discardableResult
    public mutating func addModelUsage(_ usage: TokenUsage, model: String) -> Double {
        var total = summary.modelUsage[model] ?? TokenUsage()
        total.inputTokens += usage.inputTokens
        total.outputTokens += usage.outputTokens
        total.cacheReadInputTokens += usage.cacheReadInputTokens
        total.cacheCreationInputTokens += usage.cacheCreationInputTokens
        summary.modelUsage[model] = total

        let cost = cost(of: usage, model: model)
        summary.modelCost += cost
        return cost
    }

    /// What a response with this usage costs, without recording it.
    public func cost(of usage: TokenUsage, model: String) -> Double {
        prices.models[model]?.cost(of: usage) ?? 0
    }
}

extension ModelPrice {
    /// Dollars for one request. Above `longPromptThreshold` prompt tokens (cached
    /// or not) every token of the request is billed at the long-prompt rates.
    public func cost(of usage: TokenUsage) -> Double {
        var rates = (input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
        if let threshold = longPromptThreshold, usage.promptTokens > threshold {
            rates = (
                longPromptInput ?? input, longPromptOutput ?? output, longPromptCacheRead ?? cacheRead,
                longPromptCacheWrite ?? cacheWrite
            )
        }
        let dollars =
            Double(usage.inputTokens) * rates.input + Double(usage.outputTokens) * rates.output
            + Double(usage.cacheReadInputTokens) * rates.cacheRead
            + Double(usage.cacheCreationInputTokens) * rates.cacheWrite
        return dollars / 1_000_000
    }
}
