import Foundation

/// Turns a recognizer's volatile and final results into `SpeechEvent`s on the channel's
/// timeline. It handles what Apple's SpeechTranscriber leaves to the client:
/// - Volatile text is windowed: after a final, the next volatile result only holds the
///   words since. Words of the old volatile text that a final did not cover stay on as
///   the interim instead of vanishing until the next volatile result.
/// - A volatile result that finalisation left unchanged need not be resent as final.
///   Its words are promoted once the recognizer reports it has settled past them, and
///   when the session ends.
/// - The volatile and the final decoding of a word can be timed so differently that
///   they do not overlap. A volatile word that repeats the final word next to it is
///   that stale copy, and is dropped rather than promoted as a word of its own.
/// - A forced final can come back as punctuation only ("......."). That is dropped.
/// - Some fillers come marked with a "#" ("#um", "#ah"). The mark is dropped, so they
///   read like any other filler.
///
/// One mapper serves a channel across several recognizer sessions, one after another.
public struct VolatileResultMapper: Sendable {
    /// Channel seconds up to which the recognizer has settled everything.
    public private(set) var finalizedThrough = 0.0

    private var offset = 0.0
    private var volatileWords: [Word] = []
    private var shownInterim = ""
    /// The last few words settled as final, to tell a stale volatile copy of one from
    /// a new word.
    private var recentFinal: [Word] = []

    /// Recognizer times are only ever compared at word boundaries, so a few milliseconds
    /// of slack is enough to absorb rounding.
    private let tolerance = 0.01
    /// How far after a final word its stale volatile copy can start. A word said again
    /// after a real pause starts later than this.
    private let staleCopyGap = 0.5
    private let recentFinalCount = 8

    public init() {}

    /// Starts mapping a recognizer session whose time zero is `offset` channel seconds.
    /// It hears none of the audio earlier sessions settled, so it cannot repeat them.
    public mutating func beginSession(at offset: Double) {
        self.offset = offset
        recentFinal = []
    }

    public mutating func map(_ result: RecognizerResult) -> [SpeechEvent] {
        let words = words(of: result)
        var events: [SpeechEvent] = []
        if result.isFinal {
            let start = shifted(result.start) ?? words.first?.start ?? finalizedThrough
            let end = shifted(result.end) ?? words.last?.end ?? start
            let settledEdge = max(end, shifted(result.finalizedThrough) ?? end)
            // Volatile words the final's range overlaps are replaced by it. Those on
            // either side are kept, unless they repeat the final's words next to them.
            var before = volatileWords.filter { $0.end <= start + tolerance }
            before.removeLast(repeatedRun(endOf: before, startOf: words))
            settle(before, into: &events)
            settle(words, into: &events)
            var after = volatileWords.filter { $0.start >= end - tolerance }
            after.removeFirst(repeatedRun(endOf: recentFinal, startOf: after))
            let settledAfter = after.filter { $0.end <= settledEdge + tolerance }
            settle(settledAfter, into: &events)
            volatileWords = Array(after.dropFirst(settledAfter.count))
            finalizedThrough = max(finalizedThrough, settledEdge)
        } else {
            let settledEdge = shifted(result.finalizedThrough) ?? shifted(result.start) ?? finalizedThrough
            settle(volatileWords.filter { $0.end <= settledEdge + tolerance }, into: &events)
            volatileWords = Array(words.dropFirst(repeatedRun(endOf: recentFinal, startOf: words)))
            finalizedThrough = max(finalizedThrough, settledEdge)
        }
        showInterim(into: &events)
        return events
    }

    /// The session finished after finalizing all its audio, so whatever is still
    /// volatile was settled unchanged.
    public mutating func endSession() -> [SpeechEvent] {
        var events: [SpeechEvent] = []
        settle(volatileWords, into: &events)
        if let end = volatileWords.last?.end {
            finalizedThrough = max(finalizedThrough, end)
        }
        volatileWords = []
        showInterim(into: &events)
        return events
    }

    /// The session stopped before it settled what is still volatile, and the next one
    /// hears that audio again, so the volatile words are dropped rather than promoted.
    public mutating func discardVolatile() -> [SpeechEvent] {
        var events: [SpeechEvent] = []
        volatileWords = []
        showInterim(into: &events)
        return events
    }

    private struct Word: Sendable {
        var text: String
        var start: Double
        var end: Double
    }

    private mutating func settle(_ words: [Word], into events: inout [SpeechEvent]) {
        let text = Self.joined(words)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
            return
        }
        events.append(SpeechEvent(kind: .final, text: text, audioStart: words.first?.start, audioEnd: words.last?.end))
        recentFinal = Array((recentFinal + words).suffix(recentFinalCount))
        // A final ends the interim it settles, so any words still volatile must be shown again.
        shownInterim = ""
    }

    /// How many words at the start of `later` repeat as many at the end of `earlier`.
    private func repeatedRun(endOf earlier: [Word], startOf later: [Word]) -> Int {
        let longest = min(earlier.count, later.count)
        return (0...longest).last { count in
            zip(earlier.suffix(count), later.prefix(count)).allSatisfy { repeats($1, $0) }
        } ?? 0
    }

    /// Whether `later` is `earlier` heard again: the same word, whatever its case and
    /// punctuation, starting at most `staleCopyGap` after it.
    private func repeats(_ later: Word, _ earlier: Word) -> Bool {
        let spoken = Self.spoken(earlier.text)
        return !spoken.isEmpty && spoken == Self.spoken(later.text) && later.start - earlier.end <= staleCopyGap
    }

    private static func spoken(_ text: String) -> String {
        withoutFillerMarks(text).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private mutating func showInterim(into events: inout [SpeechEvent]) {
        let text = Self.joined(volatileWords)
        if text == shownInterim {
            return
        }
        shownInterim = text
        events.append(
            SpeechEvent(
                kind: .interim, text: text, audioStart: volatileWords.first?.start, audioEnd: volatileWords.last?.end))
    }

    /// Recognizers leave some pieces untimed, typically spaces and punctuation. Those join
    /// the timed piece before them (or after, at the start), so every word has times.
    private func words(of result: RecognizerResult) -> [Word] {
        var words: [Word] = []
        var untimedLead = ""
        for piece in result.pieces {
            if let start = shifted(piece.start), let end = shifted(piece.end) {
                words.append(Word(text: untimedLead + piece.text, start: start, end: end))
                untimedLead = ""
            } else if words.isEmpty {
                untimedLead += piece.text
            } else {
                words[words.count - 1].text += piece.text
            }
        }
        if words.isEmpty, !untimedLead.isEmpty {
            let start = shifted(result.start) ?? finalizedThrough
            words.append(Word(text: untimedLead, start: start, end: shifted(result.end) ?? start))
        }
        return words
    }

    private func shifted(_ time: Double?) -> Double? {
        guard let time, time.isFinite else {
            return nil
        }
        return time + offset
    }

    private static func joined(_ words: [Word]) -> String {
        withoutFillerMarks(words.map(\.text).joined()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops a "#" at the start of a word ("#um"), leaving any other "#" ("#1", "C#").
    static func withoutFillerMarks(_ text: String) -> String {
        guard text.contains("#") else {
            return text
        }
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(characters.count)
        for (index, character) in characters.enumerated() {
            let startsWord = index == 0 || !(characters[index - 1].isLetter || characters[index - 1].isNumber)
            if character == "#", startsWord, index + 1 < characters.count, characters[index + 1].isLetter {
                continue
            }
            result.append(character)
        }
        return result
    }
}
