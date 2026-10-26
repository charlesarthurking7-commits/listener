import Foundation

/// Milliseconds between the stages of one answer. A stage is nil when it did not
/// happen, for example no speech before the hotkey or a request that failed.
public struct AnswerLatency: Sendable, Codable, Equatable {
    /// The end of the speech being answered (local VAD) to the hotkey press: your
    /// reaction time. That is the latest speech, Them's if they have spoken, unless the
    /// speaker was still talking, or had started again, at the hotkey; then it is the
    /// speech before. Filled in after the answer ends when the speech's end comes later.
    public var endOfSpeechToHotkey: Double?
    /// The speech-to-text final for that speech to the hotkey. Negative when the final
    /// arrived after the hotkey, i.e. the answer was built from interim text.
    public var finalToHotkey: Double?
    /// The hotkey to the response beginning (`ModelEvent.accepted`). Much less than
    /// `hotkeyToFirstToken` means the wait was the model; about the same, the
    /// connection, the queue or reading the prompt, or headers held for the first output.
    public var hotkeyToAccepted: Double?
    public var hotkeyToFirstToken: Double?
    public var hotkeyToDone: Double?
    /// The spec's headline number: target 1.5 s.
    public var endOfSpeechToFirstToken: Double?

    public init() {}
}

public struct AnswerRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: Int
    public var tier: AnswerTier
    public var model: String
    /// Session seconds when the hotkey was pressed.
    public var askedAt: Double
    public var text = ""
    public var latency = AnswerLatency()
    public var usage: TokenUsage?
    public var cost: Double = 0
    public var error: String?
    /// Shown from an answer drafted ahead when Them finished a turn
    /// (`AnswerSettings.draftAhead`). Its request went out before the hotkey, so
    /// `hotkeyToAccepted` is negative and the other stages measure when text appeared.
    public var fromDraft = false
}

public struct CostSummary: Sendable, Codable, Equatable {
    /// Seconds of audio sent to speech-to-text, keyed by Speaker raw value.
    public var speechSeconds: [String: Double]
    public var speechCost: Double
    /// Token usage summed per model ID.
    public var modelUsage: [String: TokenUsage]
    public var modelCost: Double

    public init(
        speechSeconds: [String: Double] = [:], speechCost: Double = 0, modelUsage: [String: TokenUsage] = [:],
        modelCost: Double = 0
    ) {
        self.speechSeconds = speechSeconds
        self.speechCost = speechCost
        self.modelUsage = modelUsage
        self.modelCost = modelCost
    }

    public var total: Double { speechCost + modelCost }
}

/// Everything the UI (or the terminal) needs to render a call, in order.
public enum SessionEvent: Sendable, Equatable {
    case started(channels: [ChannelInfo])
    case transcript(TranscriptSnapshot)
    /// The voice activity detector started or stopped hearing speech on a channel, so the
    /// window can show who it hears before any words arrive.
    case channelActivity(Speaker, isSpeaking: Bool)
    case answerStarted(id: Int, tier: AnswerTier, model: String)
    case answerText(id: Int, delta: String)
    case answerFinished(AnswerRecord)
    case answerFailed(id: Int, message: String)
    case cost(CostSummary)
    /// Something the user should know about but that does not stop the call, e.g.
    /// "Me has been digital silence for 30 s: check Microphone permission".
    case warning(String)
    case summaryStarted
    case summaryFinished(markdownFile: String?)
    /// The session ended and was saved to this directory (nil if saving failed).
    case stopped(directory: String?)
}
