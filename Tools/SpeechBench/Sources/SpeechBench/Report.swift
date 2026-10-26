import Foundation
import ListenerCore

struct SegmentResult: Codable {
    let text: String
    /// Time the engine took for this segment: how long after the speaker paused its
    /// words would appear live, on top of the pause itself.
    let seconds: Double
}

struct EngineRun: Codable {
    let engine: String
    var loadSeconds: Double?
    var segments: [SegmentResult] = []
    var error: String?

    init(engine: String) {
        self.engine = engine
    }

    var text: String {
        segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct Report {
    let segmentation: SpeechSegmentation
    let offset: Double
    /// The speech threshold the segments were cut with, in dBFS.
    let threshold: Double
    let runs: [EngineRun]
    let reference: String?

    static func describe(_ audio: SpeechSegmentation, offset: Double, threshold: Double) -> String {
        var lines = [
            "Audio: \(clock(audio.duration)) from \(clock(offset)), speech for \(clock(audio.speechSeconds))"
                + " (\(percent(audio.speechSeconds / max(audio.duration, 1))))",
            "Segments: \(audio.segments.count), longest unbroken speech \(seconds(audio.longestBurst))",
            "Levels: quietest tenth \(decibels(audio.quietDBFS)), median \(decibels(audio.medianDBFS)),"
                + " loudest tenth \(decibels(audio.loudDBFS)); speech counts above \(decibels(threshold))",
        ]
        if audio.quietDBFS > threshold {
            lines.append(
                "Warning: even the quiet parts are above the speech threshold, so Listener hears this channel"
                    + " as one long turn and never sees the pauses.")
        }
        return lines.joined(separator: "\n")
    }

    func summary() -> String {
        var header = ["Engine", "Words", "Per min", "Repeats"]
        if reference != nil {
            header.append("WER")
        }
        header += ["Speed", "Segment p50", "p90", "Max", "Load"]

        let rows = runs.map { run -> [String] in
            guard run.error == nil || !run.segments.isEmpty else {
                return [run.engine, "failed"] + Array(repeating: "", count: header.count - 2)
            }
            let metrics = Metrics(run, segments: segmentation.segments, reference: reference)
            var row = [
                run.engine + (run.error == nil ? "" : " (stopped early)"),
                "\(metrics.words)",
                String(format: "%.0f", metrics.wordsPerMinute),
                Self.percent(metrics.repeatedShare),
            ]
            if let score = metrics.score {
                row.append(Self.percent(score.rate))
            }
            row += [
                String(format: "%.0fx", metrics.speed),
                Self.seconds(metrics.p50),
                Self.seconds(metrics.p90),
                Self.seconds(metrics.max),
                run.loadSeconds.map(Self.seconds) ?? "",
            ]
            return row
        }

        var text = TextTable.render(headers: header, rows: rows, leftAligned: [0])
        text += "\nWords per min counts minutes of speech, not of the call. Repeats are words said twice in a row"
        text += "\n(\"to to\"). Speed is seconds of audio per second of work; the segment times are the extra wait"
        text += "\nafter a speaker pauses before an engine's words would appear live."

        let finished = runs.filter { !$0.segments.isEmpty }
        if finished.count > 1 {
            text += "\n\nHow far apart the engines are (word error rate of each column against each row; low means"
            text += " they agree):\n"
            let matrix = finished.map { row in
                [row.engine]
                    + finished.map { column in
                        row.engine == column.engine
                            ? "-" : Self.percent(WordErrorRate(reference: row.text, hypothesis: column.text).rate)
                    }
            }
            text += TextTable.render(headers: [""] + finished.map(\.engine), rows: matrix, leftAligned: [0])
        }
        return text
    }

    func write(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for run in runs {
            let lines = zip(segmentation.segments, run.segments).map { span, result in
                "[\(time(span))] \(result.text)"
            }
            try lines.joined(separator: "\n").write(
                to: folder.appendingPathComponent("\(run.engine).txt"), atomically: true, encoding: .utf8)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Results(offset: offset, segments: segmentation.segments, runs: runs))
            .write(to: folder.appendingPathComponent("results.json"))
        try html().write(to: folder.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)
    }

    private func html() -> String {
        let header = runs.map { "<th>\(escape($0.engine))</th>" }.joined()
        let rows = segmentation.segments.enumerated().map { index, span in
            let cells = runs.map { run in
                guard index < run.segments.count else {
                    return "<td></td>"
                }
                let result = run.segments[index]
                return "<td>\(escape(result.text))<span class=\"took\">\(Self.seconds(result.seconds))</span></td>"
            }
            return "<tr><td class=\"time\">\(time(span))</td>\(cells.joined())</tr>"
        }
        return """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Speech Bench</title>
            <style>
            :root { --bg: #ffffff; --text: #1d1d1f; --muted: #6e6e73; --line: #e5e5ea; --head: #f5f5f7; }
            @media (prefers-color-scheme: dark) {
              :root { --bg: #1c1c1e; --text: #f5f5f7; --muted: #98989d; --line: #38383a; --head: #2c2c2e; }
            }
            body { margin: 24px 16px; background: var(--bg); color: var(--text);
                   font: 14px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; }
            h1 { font-size: 20px; margin: 0 0 12px; }
            pre { font: 12px/1.5 ui-monospace, Menlo, monospace; background: var(--head); padding: 12px;
                  border-radius: 8px; overflow-x: auto; }
            .scroll { overflow-x: auto; }
            table { border-collapse: collapse; min-width: 100%; }
            th, td { text-align: left; vertical-align: top; padding: 8px 10px; border-bottom: 1px solid var(--line); }
            th { position: sticky; top: 0; background: var(--head); font-weight: 600; white-space: nowrap; }
            td { min-width: 220px; }
            td.time { min-width: 0; white-space: nowrap; color: var(--muted); font-variant-numeric: tabular-nums; }
            .took { display: block; margin-top: 2px; font-size: 11px; color: var(--muted); }
            </style>
            </head>
            <body>
            <h1>Speech Bench</h1>
            <pre>\(escape(Self.describe(segmentation, offset: offset, threshold: threshold) + "\n\n" + summary()))</pre>
            <div class="scroll"><table>
            <tr><th>Time</th>\(header)</tr>
            \(rows.joined(separator: "\n"))
            </table></div>
            </body>
            </html>
            """
    }

    private func time(_ span: AudioSpan) -> String {
        "\(Self.clock(span.start + offset, tenths: true))-\(Self.clock(span.end + offset, tenths: true))"
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func clock(_ seconds: Double, tenths: Bool = false) -> String {
        let minutes = Int(seconds) / 60
        let rest = seconds - Double(minutes * 60)
        return tenths ? String(format: "%d:%04.1f", minutes, rest) : String(format: "%d:%02d", minutes, Int(rest))
    }

    static func seconds(_ value: Double) -> String {
        String(format: value < 10 ? "%.2f s" : "%.0f s", value)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    static func decibels(_ value: Double) -> String {
        String(format: "%.0f dBFS", value)
    }
}

private struct Metrics {
    let words: Int
    let wordsPerMinute: Double
    let repeatedShare: Double
    let speed: Double
    let p50: Double
    let p90: Double
    let max: Double
    let score: WordErrorRate?

    init(_ run: EngineRun, segments: [AudioSpan], reference: String?) {
        let spoken = WordErrorRate.words(in: run.text)
        let audioSeconds = segments.prefix(run.segments.count).reduce(0) { $0 + $1.duration }
        let workSeconds = run.segments.reduce(0) { $0 + $1.seconds }
        let times = run.segments.map(\.seconds).sorted()
        words = spoken.count
        wordsPerMinute = audioSeconds > 0 ? Double(spoken.count) / audioSeconds * 60 : 0
        let repeats = zip(spoken, spoken.dropFirst()).filter { $0 == $1 }.count
        repeatedShare = spoken.isEmpty ? 0 : Double(repeats) / Double(spoken.count)
        speed = workSeconds > 0 ? audioSeconds / workSeconds : 0
        p50 = times.isEmpty ? 0 : times[times.count / 2]
        p90 = times.isEmpty ? 0 : times[Int(Double(times.count - 1) * 0.9)]
        max = times.last ?? 0
        score = reference.map { WordErrorRate(reference: $0, hypothesis: run.text) }
    }
}

private struct Results: Codable {
    let offset: Double
    let segments: [AudioSpan]
    let runs: [EngineRun]
}
