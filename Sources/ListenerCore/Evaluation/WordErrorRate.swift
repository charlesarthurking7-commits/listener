import Foundation

/// How far a recognizer's words are from a reference transcript: the fewest
/// substitutions, deletions and insertions that turn one into the other. Both texts are
/// normalised the same way first (lower case, punctuation dropped), so only the words
/// count.
public struct WordErrorRate: Sendable, Equatable {
    public let substitutions: Int
    public let deletions: Int
    public let insertions: Int
    public let referenceWords: Int

    public var errors: Int { substitutions + deletions + insertions }

    /// Errors per reference word. Above 1 when the hypothesis adds more words than the
    /// reference has.
    public var rate: Double {
        if referenceWords == 0 {
            return errors == 0 ? 0 : 1
        }
        return Double(errors) / Double(referenceWords)
    }

    public init(reference: String, hypothesis: String) {
        self.init(reference: Self.words(in: reference), hypothesis: Self.words(in: hypothesis))
    }

    public init(reference: [String], hypothesis: [String]) {
        referenceWords = reference.count
        // One row of the edit-distance table at a time, each cell keeping how its cost
        // splits into the three kinds of error.
        var previous = (0...hypothesis.count).map { Edits(insertions: $0) }
        var current = previous
        for (row, word) in reference.enumerated() {
            current[0] = Edits(deletions: row + 1)
            for (index, candidate) in hypothesis.enumerated() {
                let column = index + 1
                if word == candidate {
                    current[column] = previous[index]
                    continue
                }
                var substituted = previous[index]
                substituted.substitutions += 1
                var deleted = previous[column]
                deleted.deletions += 1
                var inserted = current[column - 1]
                inserted.insertions += 1
                current[column] = min(substituted, deleted, inserted)
            }
            swap(&previous, &current)
        }
        let best = previous[hypothesis.count]
        substitutions = best.substitutions
        deletions = best.deletions
        insertions = best.insertions
    }

    /// Lower-case words with punctuation removed. Apostrophes inside words stay, so
    /// "don't" is one word; hyphens split, so "follow-up" matches "follow up".
    public static func words(in text: String) -> [String] {
        var words: [String] = []
        var word = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else if (character == "'" || character == "\u{2019}") && !word.isEmpty {
                word.append("'")
            } else if !word.isEmpty {
                words.append(word.trimmingCharacters(in: ["'"]))
                word = ""
            }
        }
        if !word.isEmpty {
            words.append(word.trimmingCharacters(in: ["'"]))
        }
        return words.filter { !$0.isEmpty }
    }
}

private struct Edits: Comparable {
    var substitutions = 0
    var deletions = 0
    var insertions = 0

    var cost: Int { substitutions + deletions + insertions }

    static func < (lhs: Edits, rhs: Edits) -> Bool {
        lhs.cost < rhs.cost
    }
}
