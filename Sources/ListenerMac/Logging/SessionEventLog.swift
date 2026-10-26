import ListenerCore
import os

/// Writes what a call does to the unified log: start and stop with the channels,
/// every answer's latency, tokens and cost, warnings and failures. Feed it every
/// SessionEvent of one call. Transcript and answer text are skipped.
///
/// Starts and stops are notices, which macOS keeps on disk; answer details are info,
/// which only `log stream` sees (they are also in the call's session.json).
public struct SessionEventLog: Sendable {
    private var cost = CostSummary()

    public init() {}

    public mutating func record(_ event: SessionEvent) {
        switch event {
        case .started(let channels):
            Log.session.notice("Call started")
            for channel in channels {
                Log.session.notice(
                    """
                    \(channel.speaker.rawValue, privacy: .public): \(channel.backend, privacy: .public), \
                    \(channel.device, privacy: .private), \(channel.nativeFormat, privacy: .public)
                    """)
            }
        case .transcript, .answerText:
            break
        case .answerStarted(let id, let tier, let model):
            Log.answers.info("Answer \(id) asked: \(tier.rawValue, privacy: .public), \(model, privacy: .public)")
        case .answerFinished(let record):
            Self.logAnswer(record)
        case .answerFailed(let id, let message):
            if message == CallSession.cancelledMessage {
                Log.answers.info("Answer \(id) cancelled")
            } else {
                Log.answers.error("Answer \(id) failed: \(message, privacy: .public)")
            }
        case .cost(let summary):
            cost = summary
        case .channelActivity:
            break
        case .warning(let message):
            Log.session.notice("\(message, privacy: .public)")
        case .summaryStarted:
            Log.session.info("Writing the summary")
        case .summaryFinished(let file):
            if let file {
                Log.session.info("Summary written to \(file, privacy: .private)")
            } else {
                Log.session.notice("No summary was written")
            }
        case .stopped(let directory):
            let cost = cost
            if let directory {
                Log.session.notice(
                    """
                    Call stopped and saved to \(directory, privacy: .private). \
                    Cost $\(cost.total, format: .fixed(precision: 4)) \
                    (speech $\(cost.speechCost, format: .fixed(precision: 4)), \
                    Claude $\(cost.modelCost, format: .fixed(precision: 4)))
                    """)
            } else {
                Log.session.error(
                    "Call stopped but could not be saved. Cost $\(cost.total, format: .fixed(precision: 4))")
            }
        }
    }

    private static func logAnswer(_ record: AnswerRecord) {
        let latency = record.latency
        let usage = record.usage ?? TokenUsage()
        let source = record.fromDraft ? ", drafted ahead" : ""
        Log.answers.info(
            """
            Answer \(record.id) finished (\(record.tier.rawValue, privacy: .public), \
            \(record.model, privacy: .public)\(source, privacy: .public)). \
            Hotkey to first token \(ms(latency.hotkeyToFirstToken), privacy: .public), \
            end of speech to first token \(ms(latency.endOfSpeechToFirstToken), privacy: .public), \
            hotkey to accepted \(ms(latency.hotkeyToAccepted), privacy: .public), \
            hotkey to done \(ms(latency.hotkeyToDone), privacy: .public), \
            end of speech to hotkey \(ms(latency.endOfSpeechToHotkey), privacy: .public), \
            final to hotkey \(ms(latency.finalToHotkey), privacy: .public). \
            Tokens: \(usage.inputTokens) in, \(usage.cacheReadInputTokens) cache read, \
            \(usage.cacheCreationInputTokens) cache write, \(usage.outputTokens) out. \
            Cost $\(record.cost, format: .fixed(precision: 5))
            """)
    }

    private static func ms(_ value: Double?) -> String {
        DisplayFormat.latency(milliseconds: value)
    }
}
