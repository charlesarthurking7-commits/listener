import AppKit
import ListenerCore

/// After a paste, reads the field it went into once a second for a minute, and reports
/// the names and terms the user corrects in the dictated words. A correction counts
/// once two readings in a row agree, so a word half retyped is never learned. Watching
/// ends early once the dictated words have left the field, for example because the
/// message was sent.
///
/// The field's text is only read here, on the Mac. Apps that don't share their text
/// through Accessibility are not watched at all.
@MainActor
final class CorrectionWatcher {
    private static let interval: Duration = .seconds(1)
    private static let readings = 60
    /// Text read around the dictation: room for the words before it, and for it to
    /// have grown a little while being corrected.
    private static let margin = 200

    private var task: Task<Void, Never>?

    func watch(
        _ field: AXUIElement, at location: Int, typed: String,
        onCorrections: @escaping ([CorrectionFinder.Correction]) -> Void
    ) {
        stop()
        let length = (typed as NSString).length
        guard text(of: field, at: location, length: length) != nil else {
            Log.dictation.debug("The field doesn't share its text, so it isn't watched for corrections")
            return
        }
        task = Task { [weak self] in
            var previous: [CorrectionFinder.Correction] = []
            var reported: Set<CorrectionFinder.Correction> = []
            for _ in 0..<Self.readings {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled, let self, let now = self.text(of: field, at: location, length: length) else {
                    return
                }
                let found = CorrectionFinder.corrections(typed: typed, field: now, isCommonWord: Self.isCommonWord)
                if found.isEmpty, !Self.stillHolds(typed, now) {
                    return
                }
                let settled = found.filter { previous.contains($0) && !reported.contains($0) }
                previous = found
                if !settled.isEmpty {
                    reported.formUnion(settled)
                    onCorrections(settled)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// The field's text around where the dictation went in.
    private func text(of field: AXUIElement, at location: Int, length: Int) -> String? {
        let start = max(0, location - Self.margin)
        var end = location + length + Self.margin
        if let count = field.integer(kAXNumberOfCharactersAttribute) {
            end = min(end, count)
        }
        if end > start, let text = field.string(in: CFRange(location: start, length: end - start)) {
            return text
        }
        guard let value = field.string(kAXValueAttribute).map({ $0 as NSString }) else {
            return nil
        }
        let clippedEnd = min(end, value.length)
        return clippedEnd > start ? value.substring(with: NSRange(location: start, length: clippedEnd - start)) : ""
    }

    /// Most of the dictated words are still there, so the field is still worth reading.
    private static func stillHolds(_ typed: String, _ now: String) -> Bool {
        let typedWords = Set(typed.lowercased().split(whereSeparator: \.isWhitespace))
        let nowWords = Set(now.lowercased().split(whereSeparator: \.isWhitespace))
        return !typedWords.isEmpty
            && Double(typedWords.intersection(nowWords).count) >= Double(typedWords.count) * 0.5
    }

    /// Ordinary English to the Mac's spell checker, so not a name or a term.
    private static func isCommonWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        let misspelt = checker.checkSpelling(
            of: word.lowercased(), startingAt: 0, language: "en_GB", wrap: false, inSpellDocumentWithTag: 0,
            wordCount: nil)
        return misspelt.location == NSNotFound
    }
}
