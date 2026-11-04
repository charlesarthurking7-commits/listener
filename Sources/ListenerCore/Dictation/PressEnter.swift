/// "Press enter" said at the end of a dictation: the words before it are typed, then
/// Return is pressed, which sends the message in a chat app. Only the very end counts,
/// so "type your name and press enter to log in" stays text.
public enum PressEnter {
    static let phrases = ["press enter", "press return"]

    /// What was heard without the command, and whether it ended with it.
    public static func split(_ heard: String) -> (text: String, pressesEnter: Bool) {
        var body = Substring(heard)
        body.trimSuffix { $0.isWhitespace || $0.isPunctuation }
        for phrase in phrases where body.suffix(phrase.count).lowercased() == phrase {
            var text = body.dropLast(phrase.count)
            guard text.last.map({ !$0.isLetter && !$0.isNumber }) ?? true else {
                continue
            }
            text.trimSuffix { $0.isWhitespace || ",;:-".contains($0) }
            return (String(text), true)
        }
        return (heard, false)
    }
}

extension Substring {
    fileprivate mutating func trimSuffix(while matches: (Character) -> Bool) {
        while let last, matches(last) {
            removeLast()
        }
    }
}
