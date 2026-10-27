import Foundation

/// A saved call as the main window lists it.
public struct SavedCall: Sendable, Equatable, Identifiable {
    public var directory: URL
    public var startedAt: Date
    /// Nil when the call never ended cleanly (the app crashed or was killed).
    public var duration: Double?
    public var turnCount: Int
    public var cost: CostSummary?
    /// The call type picked before Start, if any.
    public var callType: String?
    /// The summary's title. Nil before there is a summary, and for older summaries,
    /// which were titled by their date.
    public var title: String?
    public var hasSummary: Bool
    /// A summary was asked for and has not been written: it is being written now, or
    /// the next launch tries again.
    public var summaryDue: Bool
    /// The user's action items in the summary not ticked yet.
    public var myOpenActionItems: Int
    public var answerCount: Int

    public var id: URL { directory }
}

/// One call in full, for its page in the main window.
public struct CallDetail: Sendable, Equatable {
    public var call: SavedCall
    public var turns: [Turn]
    public var answers: [AnswerRecord]
    /// Nil until summary.md is written.
    public var summary: CallSummary?
    public var summaryMarkdown: String?
    /// Seconds each speaker talked for, summed over their turns.
    public var talkTime: [Speaker: Double]
}

public enum CallLibraryError: Error, Equatable {
    /// summary.md no longer has the action item: it was written again or edited.
    case actionItemNotFound
}

/// The calls saved under a sessions root, read for the main window. SessionStore
/// describes the files.
public enum CallLibrary {
    /// Every call under `root`, newest first. Transcripts are read only for calls that
    /// never ended, whose session.json has no counts yet, so this is cheap enough to run
    /// on every change to the folder.
    public static func calls(in root: URL) -> [SavedCall] {
        SessionStore.sessionDirectories(in: root).map { directory, startedAt in
            call(in: directory, startedAt: startedAt, summary: readSummary(in: directory).map(CallSummary.init))
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    /// One call with its transcript, answers and summary.
    public static func detail(in directory: URL) throws -> CallDetail {
        let turns = try SessionStore.readTurns(in: directory)
        let answers = (try? SessionStore.readAnswers(in: directory)) ?? []
        let markdown = readSummary(in: directory)
        let summary = markdown.map(CallSummary.init)
        let startedAt = SessionStore.startDate(fromDirectoryName: directory.lastPathComponent) ?? .distantPast
        var talkTime: [Speaker: Double] = [:]
        for turn in turns {
            talkTime[turn.speaker, default: 0] += max(0, turn.end - turn.start)
        }
        return CallDetail(
            call: call(in: directory, startedAt: startedAt, summary: summary, turns: turns, answers: answers),
            turns: turns, answers: answers, summary: summary, summaryMarkdown: markdown, talkTime: talkTime)
    }

    /// Ticks or unticks an action item in a call's summary.md, changing nothing else in
    /// it. Written atomically, so a crash leaves the old file or the new one. Returns
    /// the summary as it now reads.
    @discardableResult
    public static func setDone(_ done: Bool, for item: CallSummary.ActionItem, in directory: URL) throws
        -> CallSummary
    {
        let url = directory.appendingPathComponent(SessionStore.summaryFile)
        let markdown = try String(contentsOf: url, encoding: .utf8)
        guard let updated = CallSummary.setting(item, done: done, in: markdown) else {
            throw CallLibraryError.actionItemNotFound
        }
        try Data(updated.utf8).write(to: url, options: .atomic)
        return CallSummary(markdown: updated)
    }

    /// What the calls started in `now`'s calendar month cost.
    public static func costThisMonth(of calls: [SavedCall], now: Date = Date(), calendar: Calendar = .current)
        -> Double
    {
        calls.filter { calendar.isDate($0.startedAt, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + ($1.cost?.total ?? 0) }
    }

    static func readSummary(in directory: URL) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(SessionStore.summaryFile), encoding: .utf8)
    }

    /// `turns` and `answers` are what the caller has already read, if anything.
    private static func call(
        in directory: URL, startedAt: Date, summary: CallSummary?, turns: [Turn]? = nil,
        answers: [AnswerRecord]? = nil
    ) -> SavedCall {
        let header = SessionStore.header(in: directory)
        // A call that never stopped (a crash) has old counts, if any; its files say more.
        let ended = header?.endedAt != nil
        let turnCount =
            (ended ? header?.turnCount : nil) ?? turns?.count
            ?? ((try? SessionStore.readTurns(in: directory))?.count ?? 0)
        let answerCount =
            (ended ? header?.answers?.count : nil) ?? answers?.count
            ?? ((try? SessionStore.readAnswers(in: directory))?.count ?? 0)
        let start = header?.startedAt ?? startedAt
        return SavedCall(
            directory: directory,
            startedAt: start,
            duration: header?.endedAt.map { $0.timeIntervalSince(start) },
            turnCount: turnCount,
            cost: header?.cost,
            callType: header?.callType,
            title: summary?.title,
            hasSummary: summary != nil,
            summaryDue: header?.summaryDue == true,
            myOpenActionItems: summary?.myOpenActionItems ?? 0,
            answerCount: answerCount
        )
    }
}

/// Finds saved calls by the words in their title, summary and transcript, ignoring case
/// and accents. Building it reads every transcript, so it is a step of its own after
/// listing; searching is then done in memory.
public struct CallSearchIndex: Sendable {
    /// A turn holding the words, with where they are, so they can be highlighted.
    public struct Snippet: Sendable, Equatable {
        public var speaker: Speaker
        /// Seconds from the start of the call.
        public var start: Double
        public var text: String
        /// Where the words are in `text`, in order, overlaps merged.
        public var matches: [Range<String.Index>]
    }

    public struct Hit: Sendable, Equatable, Identifiable {
        public var call: SavedCall
        /// The turn with the most of the words, the earliest of equals. Nil when none of
        /// them is in the transcript.
        public var snippet: Snippet?

        public var id: URL { call.id }
    }

    private struct Entry: Sendable {
        var call: SavedCall
        /// The whole call folded into one text, to check each word against.
        var text: [UInt8]
        var turns: [Turn]
        var foldedTurns: [[UInt8]]
    }

    private let entries: [Entry]

    /// `calls` in the order hits should come back in, as `CallLibrary.calls(in:)` lists them.
    public init(calls: [SavedCall]) {
        entries = calls.map { call in
            let turns = (try? SessionStore.readTurns(in: call.directory)) ?? []
            let foldedTurns = turns.map { Self.folded($0.text) }
            let summary = CallLibrary.readSummary(in: call.directory).map(CallSummary.init)
            let parts = (summary.map(Self.searchableText) ?? []).map(Self.folded) + foldedTurns
            return Entry(
                call: call, text: Array(parts.joined(separator: [UInt8(ascii: "\n")])), turns: turns,
                foldedTurns: foldedTurns)
        }
    }

    /// The calls holding every word of `query`, anywhere in the call. Nothing for an
    /// empty query.
    public func search(_ query: String) -> [Hit] {
        let words = query.split(whereSeparator: \.isWhitespace).map { Self.folded(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else {
            return []
        }
        return entries.compactMap { entry in
            guard words.allSatisfy({ Self.occurs($0, in: entry.text) }) else {
                return nil
            }
            var best: (index: Int, words: Int)?
            for (index, text) in entry.foldedTurns.enumerated() {
                let found = words.filter { Self.occurs($0, in: text) }.count
                if found > (best?.words ?? 0) {
                    best = (index, found)
                }
            }
            let snippet = best.map { best in
                let turn = entry.turns[best.index]
                return Snippet(
                    speaker: turn.speaker, start: turn.start, text: turn.text,
                    matches: Self.ranges(of: query.split(whereSeparator: \.isWhitespace), in: turn.text))
            }
            return Hit(call: entry.call, snippet: snippet)
        }
    }

    /// Lowercased and without accents, as UTF-8.
    private static func folded(_ text: String) -> [UInt8] {
        // Most of a transcript is ASCII, which only needs lowercasing, and much faster so.
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            return text.utf8.map { (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) ? $0 + 32 : $0 }
        }
        return Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).utf8)
    }

    /// Whether `word` is in `text`, byte by byte: String.contains is too slow to run over
    /// every transcript at each keystroke. In UTF-8 a whole character only ever matches
    /// whole characters.
    private static func occurs(_ word: [UInt8], in text: [UInt8]) -> Bool {
        guard let first = word.first, word.count <= text.count else {
            return word.isEmpty
        }
        let lastStart = text.count - word.count
        var from = 0
        while let start = text[from...lastStart].firstIndex(of: first) {
            if text[start..<start + word.count].elementsEqual(word) {
                return true
            }
            guard start < lastStart else {
                return false
            }
            from = start + 1
        }
        return false
    }

    private static func searchableText(of summary: CallSummary) -> [String] {
        [summary.title].compactMap { $0 } + summary.summary + summary.decisions + summary.actionItems.map(\.text)
            + summary.openQuestions + [summary.email?.subject, summary.email?.body].compactMap { $0 }
            + summary.other.flatMap { [$0.heading, $0.text] }
    }

    private static func ranges(of words: [Substring], in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for word in words {
            var from = text.startIndex
            while let range = text.range(
                of: word, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex),
                !range.isEmpty
            {
                found.append(range)
                from = range.upperBound
            }
        }
        var merged: [Range<String.Index>] = []
        for range in found.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
