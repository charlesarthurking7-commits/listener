import Foundation

/// Turns a recognizer's volatile and final results into `SpeechEvent`s on the channel's
/// timeline. It handles what Apple's SpeechTranscriber leaves to the client:
/// - Volatile text is windowed: after a final, the next volatile result only holds the
///   words since. Words of the old volatile text that a final did not cover stay on as
///   the interim instead of vanishing until the next volatile result.
/// - A volatile result that finalisation left unchanged need not be resent as final.
///   Its words are promoted once the recognizer reports it has settled past them, and
///   when the session ends.
/// - A forced final can come back as punctuation only ("......."). That is dropped.
///
/// One mapper serves a channel across several recognizer sessions, one after another.
public struct VolatileResultMapper: Sendable {
    /// Channel seconds up to which the recognizer has settled everything.
    public private(set) var finalizedThrough = 0.0

    private var offset = 0.0
    private var volatileWords: [Word] = []
    private var shownInterim = ""

    /// Recognizer times are only ever compared at word boundaries, so a few milliseconds
    /// of slack is enough to absorb rounding.
    private let tolerance = 0.01

    public init() {}

    /// Starts mapping a recognizer session whose time zero is `offset` channel seconds.
    public mutating func beginSession(at offset: Double) {
        self.offset = offset
    }

    public mutating func map(_ result: RecognizerResult) -> [SpeechEvent] {
        let words = words(of: result)
        var events: [SpeechEvent] = []
        if result.isFinal {
            let start = shifted(result.start) ?? words.first?.start ?? finalizedThrough
            let end = shifted(result.end) ?? words.last?.end ?? start
            let settledEdge = max(end, shifted(result.finalizedThrough) ?? end)
            let after = volatileWords.filter { $0.start >= end - tolerance }
            let settledAfter = after.filter { $0.end <= settledEdge + tolerance }

            settle(volatileWords.filter { $0.end <= start + tolerance }, into: &events)
            settle(words, into: &events)
            settle(settledAfter, into: &events)
            volatileWords = Array(after.dropFirst(settledAfter.count))
            finalizedThrough = max(finalizedThrough, settledEdge)
        } else {
            let settledEdge = shifted(result.finalizedThrough) ?? shifted(result.start) ?? finalizedThrough
            settle(volatileWords.filter { $0.end <= settledEdge + tolerance }, into: &events)
            volatileWords = words
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
        // A final ends the interim it settles, so any words still volatile must be shown again.
        shownInterim = ""
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
        words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
