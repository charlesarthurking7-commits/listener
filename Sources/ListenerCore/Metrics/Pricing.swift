/// Prices in US dollars per million tokens. Kept in settings so a price change is an
/// edit to settings.json, not a code change.
public struct ModelPrice: Sendable, Codable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    /// Five-minute cache writes.
    public var cacheWrite: Double
    /// Some models charge more once a prompt is longer than this many tokens
    /// (Haiku 5.5 above 100k). The long rates then apply to the whole request.
    public var longPromptThreshold: Int?
    public var longPromptInput: Double?
    public var longPromptOutput: Double?
    public var longPromptCacheRead: Double?
    public var longPromptCacheWrite: Double?

    public init(
        input: Double,
        output: Double,
        cacheRead: Double,
        cacheWrite: Double,
        longPromptThreshold: Int? = nil,
        longPromptInput: Double? = nil,
        longPromptOutput: Double? = nil,
        longPromptCacheRead: Double? = nil,
        longPromptCacheWrite: Double? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.longPromptThreshold = longPromptThreshold
        self.longPromptInput = longPromptInput
        self.longPromptOutput = longPromptOutput
        self.longPromptCacheRead = longPromptCacheRead
        self.longPromptCacheWrite = longPromptCacheWrite
    }
}

public struct PriceTable: Sendable, Codable, Equatable {
    public var models: [String: ModelPrice]
    /// Dollars per minute of audio, per channel, keyed by speech provider name.
    public var speechPerMinute: [String: Double]

    public init(models: [String: ModelPrice], speechPerMinute: [String: Double]) {
        self.models = models
        self.speechPerMinute = speechPerMinute
    }

    /// First-party Anthropic API and Google Speech-to-Text v2 list prices, October 2026.
    public static let standard = PriceTable(
        models: [
            "claude-haiku-5-5": ModelPrice(
                input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125,
                longPromptThreshold: 100_000,
                longPromptInput: 0.50, longPromptOutput: 2.50,
                longPromptCacheRead: 0.05, longPromptCacheWrite: 0.625
            ),
            "claude-sonnet-5-5": ModelPrice(input: 2.00, output: 10.00, cacheRead: 0.20, cacheWrite: 2.50),
            "claude-opus-5-5": ModelPrice(input: 4.00, output: 20.00, cacheRead: 0.20, cacheWrite: 5.00),
        ],
        speechPerMinute: [
            "google": 0.016,
            "fake": 0,
        ]
    )
}
