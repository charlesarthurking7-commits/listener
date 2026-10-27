/// The words dictation has learned from corrections, kept in dictionary.txt as one term
/// per line with what it was heard as:
///
///     Shivani (heard as Shavani)
///     Kestrelmoor (heard as kestrel moore, Kestrel Moore)
///
/// Plain text so it can be read and pruned by hand: deleting a line forgets the word.
public struct LearnedDictionary: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var term: String
        public var heardAs: [String]

        public init(term: String, heardAs: [String] = []) {
            self.term = term
            self.heardAs = heardAs
        }
    }

    /// The oldest words go once there are more than this, as Wispr Flow also caps it.
    public static let maxEntries = 200
    static let maxHeardForms = 5

    static let header = """
        # Words Listener's dictation learned from your corrections, spelt as you corrected
        # them. Delete a line to forget a word, or add one to teach it.

        """

    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public init(text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            if let open = line.range(of: " (heard as "), line.hasSuffix(")") {
                let term = String(line[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
                let heard = line[open.upperBound..<line.index(before: line.endIndex)]
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                add(Entry(term: term, heardAs: heard))
            } else {
                add(Entry(term: line))
            }
        }
    }

    public var text: String {
        Self.header
            + entries.map { entry in
                entry.heardAs.isEmpty ? entry.term : "\(entry.term) (heard as \(entry.heardAs.joined(separator: ", ")))"
            }.joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
    }

    public func contains(_ term: String) -> Bool {
        entries.contains { $0.term == term }
    }

    /// Adds the correction. Returns whether that taught it anything new: a new word, or a
    /// new way of mishearing one it knew.
    @discardableResult
    public mutating func learn(_ correction: CorrectionFinder.Correction) -> Bool {
        if let index = entries.firstIndex(where: { $0.term == correction.term }) {
            guard !entries[index].heardAs.contains(correction.heard) else {
                return false
            }
            entries[index].heardAs = Array((entries[index].heardAs + [correction.heard]).suffix(Self.maxHeardForms))
            return true
        }
        add(Entry(term: correction.term, heardAs: [correction.heard]))
        return true
    }

    /// Adds a word typed in by hand, not yet heard as anything. Returns whether it was new.
    @discardableResult
    public mutating func add(_ term: String) -> Bool {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !term.contains(where: \.isNewline), !contains(term) else {
            return false
        }
        add(Entry(term: term))
        return true
    }

    public mutating func forget(_ term: String) {
        entries.removeAll { $0.term == term }
    }

    /// For the clean-up prompt: each term, with how the recognizer tends to write it.
    public var promptTerms: [String] {
        entries.map { entry in
            entry.heardAs.isEmpty
                ? entry.term
                : "\(entry.term) (heard as \(entry.heardAs.map { "\"\($0)\"" }.joined(separator: ", ")))"
        }
    }

    private mutating func add(_ entry: Entry) {
        guard !entry.term.isEmpty, !contains(entry.term) else {
            return
        }
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }
}
