import Foundation

public struct TerminalStyle: Sendable, Equatable {
    /// ANSI colours. Off when output is not a terminal or NO_COLOR is set.
    public var color: Bool
    /// Show interim text on one line that is rewritten in place. Off when output is
    /// a file or a pipe, where only settled turns are printed.
    public var liveLine: Bool
    /// Terminal width. The live line is cut to fit, because a wrapped line can no
    /// longer be rewritten in place.
    public var width: Int

    public init(color: Bool, liveLine: Bool, width: Int = 100) {
        self.color = color
        self.liveLine = liveLine
        self.width = width
    }

    public static let plain = TerminalStyle(color: false, liveLine: false)
}

/// Turns session events into terminal output for `listener live` and
/// `listener replay`. Settled turns print once, with a time and speaker label; what
/// people are saying right now sits on a live line below them that is rewritten in
/// place. Transcript output is held back while an answer streams, so the answer is
/// never interleaved with other text.
public struct TerminalRenderer: Sendable {
    public let style: TerminalStyle
    private var printed: [Int: String] = [:]
    private var lastPrintedTurn: Int?
    private var liveText = ""
    private var liveShown = false
    private var streamingAnswer: Int?
    private var heldBack: TranscriptSnapshot?
    public private(set) var cost = CostSummary()

    public init(style: TerminalStyle) {
        self.style = style
    }

    public mutating func render(_ event: SessionEvent) -> String {
        switch event {
        case .started(let channels):
            return channels.map { channel in
                "\(label(channel.speaker)) \(channel.device) (\(channel.backend))\n"
            }.joined()
        case .transcript(let snapshot):
            if streamingAnswer != nil {
                heldBack = snapshot
                return ""
            }
            return renderTranscript(snapshot)
        case .answerStarted(let id, let tier, let model):
            var output = clearLiveLine()
            if streamingAnswer != nil {
                output += "\n"
            }
            streamingAnswer = id
            let title =
                switch tier {
                case .quick: "Quick answer"
                case .deep: "Deep answer"
                case .recap: "Recap so far"
                }
            return output + "\n" + paint(title, .boldGreen) + paint(" (\(model))", .dim) + "\n"
        case .answerText(let id, let delta):
            return id == streamingAnswer ? delta : ""
        case .answerFinished(let record):
            guard record.id == streamingAnswer else {
                return ""
            }
            streamingAnswer = nil
            var facts = ["first token \(DisplayFormat.latency(milliseconds: record.latency.hotkeyToFirstToken))"]
            if let done = record.latency.hotkeyToDone {
                facts.append("done \(DisplayFormat.latency(milliseconds: done))")
            }
            facts.append(DisplayFormat.preciseCost(record.cost))
            if let error = record.error {
                facts.append(error)
            }
            return "\n" + paint(facts.joined(separator: ", "), .dim) + "\n\n" + releaseHeldBack()
        case .answerFailed(let id, let message):
            guard id == streamingAnswer else {
                return ""
            }
            streamingAnswer = nil
            return "\n" + paint("Answer failed: \(message)", .red) + "\n\n" + releaseHeldBack()
        case .cost(let summary):
            cost = summary
            return ""
        case .channelActivity:
            return ""
        case .warning(let message):
            let lead = streamingAnswer != nil ? "\n" : clearLiveLine()
            return lead + paint("! \(message)", .yellow) + "\n" + (streamingAnswer == nil ? showLiveLine() : "")
        case .summaryStarted:
            return clearLiveLine() + "Writing the summary...\n"
        case .summaryFinished(let file):
            return file.map { "Summary: \($0)\n" } ?? "No summary was written.\n"
        case .stopped(let directory):
            var output = clearLiveLine()
            output += directory.map { "Saved to \($0)\n" } ?? paint("The call could not be saved.", .red) + "\n"
            output +=
                "Cost \(DisplayFormat.cost(cost.total)): speech to text \(DisplayFormat.cost(cost.speechCost)), "
                + "Claude \(DisplayFormat.cost(cost.modelCost))\n"
            return output
        }
    }

    /// A line from outside the session's events, such as a capture restart. Printed
    /// dimmed above the live line; during an answer it waits on a line of its own.
    public mutating func note(_ message: String) -> String {
        let lead = streamingAnswer != nil ? "\n" : clearLiveLine()
        return lead + paint(message, .dim) + "\n" + (streamingAnswer == nil ? showLiveLine() : "")
    }

    /// The terminal echoed a line the user typed (and its newline) right after the live
    /// line. Moves back up, clears that line and draws the live line again.
    public mutating func inputEchoed() -> String {
        guard style.liveLine, streamingAnswer == nil else {
            return ""
        }
        liveShown = false
        return "\u{1B}[1A\r\u{1B}[2K" + showLiveLine()
    }

    /// Removes the live line, e.g. before printing something unrelated or exiting.
    public mutating func clearLiveLine() -> String {
        guard liveShown else {
            return ""
        }
        liveShown = false
        return "\r\u{1B}[2K"
    }

    private mutating func renderTranscript(_ snapshot: TranscriptSnapshot) -> String {
        let lines = newLines(snapshot.turns)
        let live = style.liveLine ? liveLine(snapshot.interim) : ""
        if lines.isEmpty && live == liveText && (liveShown || live.isEmpty) {
            return ""
        }
        liveText = live
        var output = clearLiveLine()
        for line in lines {
            output += line + "\n"
        }
        return output + showLiveLine()
    }

    private mutating func releaseHeldBack() -> String {
        guard let snapshot = heldBack else {
            return showLiveLine()
        }
        heldBack = nil
        return renderTranscript(snapshot)
    }

    private mutating func showLiveLine() -> String {
        guard !liveText.isEmpty else {
            return ""
        }
        liveShown = true
        return paint(liveText, .dim)
    }

    /// Lines for turns that are new or have grown since they were printed.
    private mutating func newLines(_ turns: [Turn]) -> [String] {
        var lines: [String] = []
        for turn in turns {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let before = printed[turn.id]
            if text.isEmpty || text == before {
                continue
            }
            if let before, text.hasPrefix(before), lastPrintedTurn == turn.id {
                let rest = text.dropFirst(before.count).trimmingCharacters(in: .whitespaces)
                lines.append(String(repeating: " ", count: headerWidth(turn)) + rest)
            } else if let before, text.hasPrefix(before) {
                lines.append(header(turn) + text.dropFirst(before.count).trimmingCharacters(in: .whitespaces))
            } else {
                lines.append(header(turn) + text)
            }
            printed[turn.id] = text
            lastPrintedTurn = turn.id
        }
        return lines
    }

    private func header(_ turn: Turn) -> String {
        paint("[\(DisplayFormat.clock(turn.start))]", .dim) + " " + label(turn.speaker) + "  "
    }

    private func headerWidth(_ turn: Turn) -> Int {
        "[\(DisplayFormat.clock(turn.start))] ".count + 4 + 2
    }

    private func label(_ speaker: Speaker) -> String {
        let padded = speaker.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0)
        return paint(padded, speaker == .me ? .boldCyan : .boldMagenta)
    }

    private func liveLine(_ interim: [Speaker: String]) -> String {
        let parts = Speaker.allCases.compactMap { speaker -> String? in
            let text = interim[speaker, default: ""].split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : "\(speaker.rawValue): \(text)"
        }
        if parts.isEmpty {
            return ""
        }
        let line = "... " + parts.joined(separator: "  |  ")
        let room = max(style.width - 1, 10)
        if line.count <= room {
            return line
        }
        return "..." + line.suffix(room - 3)
    }

    private enum Paint: String {
        case dim = "2"
        case red = "31"
        case yellow = "33"
        case boldGreen = "1;32"
        case boldCyan = "1;36"
        case boldMagenta = "1;35"
    }

    private func paint(_ text: String, _ paint: Paint) -> String {
        style.color ? "\u{1B}[\(paint.rawValue)m\(text)\u{1B}[0m" : text
    }
}
