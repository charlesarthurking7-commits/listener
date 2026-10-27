/// Finds the spelling fixes made to dictated text after it was pasted: a word or two
/// swapped for ones that sound much the same and look like a name or a term ("Shavani"
/// to "Shivani", "kestrel moore" to "Kestrelmoor", "fix" to "FIX"). Rewording, new
/// sentences and fixes to ordinary words are left alone: those are edits, not spellings
/// the speech recognizer keeps getting wrong.
public enum CorrectionFinder {
    public struct Correction: Sendable, Equatable, Hashable {
        /// What dictation typed.
        public var heard: String
        /// What the user changed it to.
        public var term: String

        public init(heard: String, term: String) {
            self.heard = heard
            self.term = term
        }
    }

    /// Below this share of the dictated words still in the field, the text has been
    /// rewritten or sent, and nothing in it is a correction.
    static let minimumKept = 0.6
    static let maxHeardWords = 2
    static let maxTermWords = 3
    static let maxTermCharacters = 40

    /// - Parameters:
    ///   - typed: what dictation pasted.
    ///   - field: the field's text around where it went, as it is now.
    ///   - isCommonWord: whether a word is ordinary English, in any capitalisation.
    public static func corrections(
        typed: String, field: String, isCommonWord: (String) -> Bool
    ) -> [Correction] {
        let typedWords = words(typed)
        let fieldWords = words(field)
        guard !typedWords.isEmpty, !fieldWords.isEmpty else {
            return []
        }
        let matches = alignment(typedWords.map(\.exact), fieldWords.map(\.exact))
        guard Double(matches.count) >= Double(typedWords.count) * minimumKept, let first = matches.first,
            let last = matches.last
        else {
            return []
        }
        var found: [Correction] = []
        @discardableResult
        func consider(_ heard: ArraySlice<Word>, _ term: ArraySlice<Word>, sentenceStart: Bool) -> Bool {
            guard let correction = correction(heard, term, sentenceStart: sentenceStart, isCommonWord: isCommonWord)
            else {
                return false
            }
            if !found.contains(correction) {
                found.append(correction)
            }
            return true
        }
        func startsSentence(_ index: Int) -> Bool {
            index == 0 || fieldWords[index - 1].text.last.map { ".!?:\n".contains($0) } == true
        }
        // A fix to the first or last words runs into the text around the dictation, so
        // the fewest words of the field on that side that make a correction are it.
        if first.typed > 0, first.typed <= maxHeardWords {
            let heard = typedWords[..<first.typed]
            for count in 1...maxTermWords where count <= first.field {
                let start = first.field - count
                if consider(heard, fieldWords[start..<first.field], sentenceStart: startsSentence(start)) {
                    break
                }
            }
        }
        for (before, after) in zip(matches, matches.dropFirst()) {
            let heard = typedWords[(before.typed + 1)..<after.typed]
            let term = fieldWords[(before.field + 1)..<after.field]
            if !heard.isEmpty, !term.isEmpty {
                consider(heard, term, sentenceStart: startsSentence(before.field + 1))
            }
        }
        let typedTail = typedWords.count - last.typed - 1
        if typedTail > 0, typedTail <= maxHeardWords {
            let heard = typedWords[(last.typed + 1)...]
            for count in 1...maxTermWords where last.field + count < fieldWords.count {
                if consider(heard, fieldWords[(last.field + 1)...(last.field + count)], sentenceStart: false) {
                    break
                }
            }
        }
        return found
    }

    private static func correction(
        _ heard: ArraySlice<Word>, _ term: ArraySlice<Word>, sentenceStart: Bool, isCommonWord: (String) -> Bool
    ) -> Correction? {
        guard heard.count <= maxHeardWords, term.count <= maxTermWords else {
            return nil
        }
        let heardText = heard.map(\.bare).joined(separator: " ")
        let termText = term.map(\.bare).joined(separator: " ")
        let heardLetters = heard.map(\.key).joined()
        let termLetters = term.map(\.key).joined()
        guard !termLetters.isEmpty, termText.count <= maxTermCharacters, heardText != termText,
            termLetters.contains(where: \.isLetter)
        else {
            return nil
        }
        if heardLetters != termLetters {
            let limit = max(1, Int(Double(max(heardLetters.count, termLetters.count)) * 0.4))
            guard editDistance(heardLetters, termLetters, limit: limit) <= limit else {
                return nil
            }
        }
        guard looksLikeATerm(term.map(\.bare), sentenceStart: sentenceStart, isCommonWord: isCommonWord) else {
            return nil
        }
        return Correction(heard: heardText, term: termText)
    }

    /// Has a digit, a capital after its first letter (MT5, McAllister), a word that is
    /// not ordinary English, or a capital that no sentence start explains.
    private static func looksLikeATerm(
        _ words: [String], sentenceStart: Bool, isCommonWord: (String) -> Bool
    ) -> Bool {
        words.enumerated().contains { index, word in
            let letters = word.filter { $0.isLetter || $0.isNumber }
            if letters.contains(where: \.isNumber) || letters.dropFirst().contains(where: \.isUppercase) {
                return true
            }
            if !isCommonWord(letters) {
                return true
            }
            return letters.first?.isUppercase == true && !(index == 0 && sentenceStart)
        }
    }

    private struct Word {
        /// As written, with any punctuation.
        let text: String
        /// Without the punctuation around it.
        let bare: String
        /// Letters and digits only, for lining the texts up: a change of case is an edit.
        let exact: String
        /// The same in lowercase, for how alike two spellings are.
        let key: String
    }

    private static func words(_ text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).compactMap { piece in
            let text = String(piece)
            let bare = text.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            let exact = bare.filter { $0.isLetter || $0.isNumber }
            return exact.isEmpty ? nil : Word(text: text, bare: bare, exact: exact, key: exact.lowercased())
        }
    }

    /// The longest common run of words, as pairs of indices in order.
    private static func alignment(_ typed: [String], _ field: [String]) -> [(typed: Int, field: Int)] {
        let rows = typed.count
        let columns = field.count
        var lengths = [Int](repeating: 0, count: (rows + 1) * (columns + 1))
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                let here = row * (columns + 1) + column
                lengths[here] =
                    typed[row] == field[column]
                    ? lengths[here + columns + 2] + 1 : max(lengths[here + columns + 1], lengths[here + 1])
            }
        }
        var pairs: [(typed: Int, field: Int)] = []
        var row = 0
        var column = 0
        while row < rows, column < columns {
            let here = row * (columns + 1) + column
            if typed[row] == field[column] {
                pairs.append((row, column))
                row += 1
                column += 1
            } else if lengths[here + columns + 1] >= lengths[here + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        return pairs
    }

    /// Levenshtein distance, giving up once it passes `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a)
        let b = Array(b)
        if abs(a.count - b.count) > limit {
            return limit + 1
        }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + [Int](repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))
            }
            if current.min()! > limit {
                return limit + 1
            }
            previous = current
        }
        return previous[b.count]
    }
}
