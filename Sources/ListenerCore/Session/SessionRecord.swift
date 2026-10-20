import Foundation

/// What session.json holds: when the call ran, how it was set up, how fast answers came
/// and what it cost. Transcript and answer text live in their own files.
public struct SessionRecord: Sendable, Codable, Equatable {
    /// One answer's timing and cost, without its text.
    public struct AnswerTiming: Sendable, Codable, Equatable {
        public var id: Int
        public var tier: AnswerTier
        public var model: String
        public var askedAt: Double
        public var fromDraft: Bool
        public var latency: AnswerLatency
        public var usage: TokenUsage?
        public var cost: Double
        public var error: String?

        public init(_ answer: AnswerRecord) {
            id = answer.id
            tier = answer.tier
            model = answer.model
            askedAt = answer.askedAt
            fromDraft = answer.fromDraft
            latency = answer.latency
            usage = answer.usage
            cost = answer.cost
            error = answer.error
        }
    }

    public var startedAt: Date
    public var endedAt: Date?
    public var channels: [ChannelInfo]
    /// The speech-to-text provider's display name.
    public var speechProvider: String
    public var settings: Settings
    public var turnCount: Int
    public var answers: [AnswerTiming]
    /// Over answers that succeeded.
    public var latency: LatencyStats
    public var cost: CostSummary
    /// File name of the summary within the session directory, once written.
    public var summaryFile: String?

    public init(
        startedAt: Date,
        endedAt: Date? = nil,
        channels: [ChannelInfo],
        speechProvider: String,
        settings: Settings,
        turnCount: Int = 0,
        answers: [AnswerRecord] = [],
        cost: CostSummary = CostSummary(),
        summaryFile: String? = nil
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.channels = channels
        self.speechProvider = speechProvider
        self.settings = settings
        self.turnCount = turnCount
        self.answers = answers.map(AnswerTiming.init)
        latency = LatencyStats(answers.filter { $0.error == nil }.map(\.latency))
        self.cost = cost
        self.summaryFile = summaryFile
    }

    /// Seconds from start to end, once the session has ended.
    public var duration: Double? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}
