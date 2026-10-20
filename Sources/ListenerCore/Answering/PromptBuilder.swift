/// Turns the transcript into model requests. Placeholder: the full version adds the
/// stepped, cache-friendly transcript window and the real system prompts.
public struct PromptBuilder: Sendable {
    public var answers: AnswerSettings

    public init(answers: AnswerSettings) {
        self.answers = answers
    }

    /// The request for a hotkey answer. `now` is session seconds, used to mark how
    /// long ago things were said.
    public func answerRequest(tier: AnswerTier, transcript: TranscriptSnapshot, now: Double) -> ModelRequest {
        var lines: [String] = []
        for turn in transcript.turns {
            lines.append("\(turn.speaker.rawValue): \(turn.text)")
        }
        return ModelRequest(
            settings: answers.settings(for: tier),
            system: "Suggest what Me should say next.",
            user: [PromptBlock(lines.joined(separator: "\n"))]
        )
    }

    /// The end-of-call request for a Markdown summary with action items.
    public func summaryRequest(turns: [Turn], settings: SummarySettings) -> ModelRequest {
        var lines: [String] = []
        for turn in turns {
            lines.append("\(turn.speaker.rawValue): \(turn.text)")
        }
        return ModelRequest(
            settings: settings.model,
            system: "Summarise this call as Markdown with action items.",
            user: [PromptBlock(lines.joined(separator: "\n"))]
        )
    }
}
