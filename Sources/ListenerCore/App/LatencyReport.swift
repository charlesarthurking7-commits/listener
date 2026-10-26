import Foundation

/// The table `listener replay --ask-at` prints at the end: one row per answer, then
/// medians against the 1.5 s target from the end of speech to the first token.
public enum LatencyReport {
    public static let targetMs = 1500.0

    public static func render(_ records: [AnswerRecord]) -> String {
        if records.isEmpty {
            return "No answers were requested.\n"
        }
        let headers = ["#", "Tier", "Asked", "Speech end > 1st token", "Hotkey > 1st token", "Hotkey > done", "Cost"]
        let rows = records.map { record in
            [
                String(record.id),
                record.tier.rawValue,
                DisplayFormat.clock(record.askedAt),
                DisplayFormat.latency(milliseconds: record.latency.endOfSpeechToFirstToken),
                DisplayFormat.latency(milliseconds: record.latency.hotkeyToFirstToken),
                DisplayFormat.latency(milliseconds: record.latency.hotkeyToDone),
                DisplayFormat.preciseCost(record.cost),
            ]
        }
        var output = TextTable.render(headers: headers, rows: rows, leftAligned: [1])

        let failures = records.filter { $0.error != nil }
        for record in failures {
            output += "Answer \(record.id) failed: \(record.error ?? "")\n"
        }
        output += "\n" + summaryLine("Hotkey to first token", records.compactMap(\.latency.hotkeyToFirstToken))
        let speechEnd = records.compactMap(\.latency.endOfSpeechToFirstToken)
        output += summaryLine("Speech end to first token", speechEnd)
        if !speechEnd.isEmpty {
            let within = speechEnd.filter { $0 <= targetMs }.count
            output +=
                "\(within) of \(speechEnd.count) within the \(DisplayFormat.latency(milliseconds: targetMs)) target\n"
        }
        return output
    }

    private static func summaryLine(_ title: String, _ values: [Double]) -> String {
        guard let median = LatencyStats.Percentiles(values)?.p50, let worst = values.max() else {
            return "\(title): no measurements\n"
        }
        return
            "\(title): median \(DisplayFormat.latency(milliseconds: median)), "
            + "worst \(DisplayFormat.latency(milliseconds: worst)) (\(values.count) answers)\n"
    }
}

/// Plain-text tables for the terminal.
public enum TextTable {
    /// Columns padded to their widest cell and separated by two spaces. Columns in
    /// `leftAligned` are padded on the right, the others (numbers) on the left.
    public static func render(headers: [String], rows: [[String]], leftAligned: Set<Int> = []) -> String {
        var widths = headers.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        func line(_ cells: [String]) -> String {
            var text = cells.enumerated().map { index, cell in
                let padding = String(repeating: " ", count: max(widths[index] - cell.count, 0))
                return leftAligned.contains(index) ? cell + padding : padding + cell
            }.joined(separator: "  ")
            while text.last == " " {
                text.removeLast()
            }
            return text + "\n"
        }
        return ([headers] + rows).map(line).joined()
    }
}

/// The times `listener replay --ask-at` asks for answers, in seconds of audio.
public enum AskSchedule {
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let text: String

        public var description: String {
            "\"\(text)\" is not a time. Use seconds (75 or 75.5) or minutes:seconds (1:15)."
        }
    }

    /// Parses "12.5,30,1:05" into sorted seconds.
    public static func parse(_ text: String) throws -> [Double] {
        try text.split(separator: ",").map { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let seconds = seconds(trimmed), seconds.isFinite, seconds >= 0 else {
                throw ParseError(text: trimmed)
            }
            return seconds
        }.sorted()
    }

    private static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return Double(text)
        case 2:
            guard let minutes = Int(parts[0]), let seconds = Double(parts[1]), seconds < 60 else {
                return nil
            }
            return Double(minutes) * 60 + seconds
        default:
            return nil
        }
    }
}
