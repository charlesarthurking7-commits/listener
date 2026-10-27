import Foundation

/// summary.md, read back for the main window. The notes come from a model, so this takes
/// what models actually write: any bullet style, headings at any level and in any order,
/// a bold line in place of a heading. Sections it does not know are kept in `other`, so
/// nothing the model wrote is lost. Inline Markdown such as **bold** stays in the text.
public struct CallSummary: Sendable, Equatable {
    public struct ActionItem: Sendable, Equatable {
        public var done: Bool
        /// "Me", "Them" or a name, from a leading "**Me**:".
        public var owner: String?
        public var text: String
        /// The item's line in the Markdown, counting from 0, for ticking it there.
        public var line: Int

        /// For the user to do: owned by Me, shared with Me, or by no one. The notes always
        /// give an owner, so one without is an item added by hand, and hiding it could
        /// lose a task.
        public var isMine: Bool {
            guard let owner else {
                return true
            }
            return owner.lowercased().split { !$0.isLetter }.contains { ["me", "you", "both"].contains($0) }
        }
    }

    public struct Email: Sendable, Equatable {
        public var subject: String?
        public var body: String

        /// The email as plain text, subject first, for pasting into a mail app.
        public var text: String {
            let body = body.replacingOccurrences(of: "**", with: "")
            guard let subject else {
                return body
            }
            return body.isEmpty ? "Subject: \(subject)" : "Subject: \(subject)\n\n\(body)"
        }
    }

    /// A section the notes are not expected to have, or text before the first section
    /// (with an empty heading).
    public struct Section: Sendable, Equatable {
        public var heading: String
        public var text: String
    }

    /// What the call was about. Nil for notes without one, such as older summaries,
    /// which were titled "Call on" and the date.
    public var title: String?
    /// When the call was and how long it took, as written under the title.
    public var dateLine: String?
    public var summary: [String] = []
    public var decisions: [String] = []
    public var actionItems: [ActionItem] = []
    public var openQuestions: [String] = []
    public var email: Email?
    public var other: [Section] = []
    /// The notes stop early: the model reached its token limit.
    public var cutShort = false

    /// The user's action items not ticked yet.
    public var myOpenActionItems: Int {
        actionItems.filter { $0.isMine && !$0.done }.count
    }

    public init(markdown: String) {
        var preamble: [Line] = []
        var titleLine: Int?
        var sections: [(heading: String, lines: [Line])] = []
        for (index, range) in Self.lineRanges(in: markdown).enumerated() {
            let raw = markdown[range]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == SessionSummarizer.cutShortNote {
                cutShort = true
            } else if let heading = Self.headingText(line) {
                if sections.isEmpty, titleLine == nil, Self.kind(of: heading) == nil {
                    titleLine = index
                    if heading.hasPrefix("Call on ") {
                        dateLine = heading
                    } else {
                        title = heading
                    }
                } else {
                    sections.append((heading, []))
                }
            } else if sections.isEmpty {
                preamble.append(Line(index: index, text: String(raw)))
            } else {
                sections[sections.count - 1].lines.append(Line(index: index, text: String(raw)))
            }
        }

        // The date line sits under the title, in italics.
        if dateLine == nil,
            let first = preamble.firstIndex(where: { $0.index > (titleLine ?? -1) && !$0.trimmed.isEmpty }),
            Self.listItem(preamble[first].text[...]) == nil,
            titleLine != nil || Self.withoutEmphasis(preamble[first].trimmed) != preamble[first].trimmed
        {
            dateLine = Self.withoutEmphasis(preamble[first].trimmed)
            preamble.remove(at: first)
        }
        let intro = Self.text(of: preamble)
        if !intro.isEmpty {
            other.append(Section(heading: "", text: intro))
        }

        for (heading, lines) in sections {
            switch Self.kind(of: heading) {
            case .summary: summary += Self.items(in: lines).map(\.text)
            case .decisions: decisions += Self.items(in: lines).map(\.text)
            case .actionItems: actionItems += Self.items(in: lines).map(Self.actionItem)
            case .openQuestions: openQuestions += Self.items(in: lines).map(\.text)
            case .email: email = email ?? Self.email(in: lines)
            case nil: other.append(Section(heading: heading, text: Self.text(of: lines)))
            }
        }
    }

    /// `markdown` with `item` ticked or unticked. Only its checkbox changes, so the rest of
    /// summary.md stays as written; an item without a checkbox gets one. The item is found
    /// by its line, or by its text if the file has changed since; nil when it is gone.
    public static func setting(_ item: ActionItem, done: Bool, in markdown: String) -> String? {
        let items = CallSummary(markdown: markdown).actionItems
        func isSame(_ other: ActionItem) -> Bool {
            other.text == item.text && other.owner == item.owner
        }
        guard let target = items.first(where: { $0.line == item.line && isSame($0) }) ?? items.first(where: isSame)
        else {
            return nil
        }
        let range = lineRanges(in: markdown)[target.line]
        var markdown = markdown
        markdown.replaceSubrange(range, with: settingCheckbox(in: String(markdown[range]), done: done))
        return markdown
    }

    private struct Line {
        var index: Int
        var text: String

        var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
    }

    /// Each line's range in `text`, without its line break. Splitting on "\n" alone would
    /// miss "\r\n", which Swift counts as one character.
    private static func lineRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        for index in text.indices where text[index].isNewline {
            ranges.append(start..<index)
            start = text.index(after: index)
        }
        ranges.append(start..<text.endIndex)
        return ranges
    }

    /// One bullet, or one paragraph in a section written without bullets.
    private struct Item {
        var line: Int
        var text: String
    }

    private enum Kind {
        case summary
        case decisions
        case actionItems
        case openQuestions
        case email
    }

    /// Heading names models use for each section, lowercased, with hyphens as spaces.
    private static let kinds: [String: Kind] = [
        "summary": .summary, "call summary": .summary, "meeting summary": .summary, "overview": .summary,
        "key points": .summary,
        "decisions": .decisions, "key decisions": .decisions, "decisions made": .decisions,
        "agreed": .decisions,
        "action items": .actionItems, "actions": .actionItems, "action points": .actionItems,
        "next steps": .actionItems, "tasks": .actionItems, "to dos": .actionItems, "todo": .actionItems,
        "open questions": .openQuestions, "questions": .openQuestions, "outstanding questions": .openQuestions,
        "unanswered questions": .openQuestions, "open items": .openQuestions,
        "follow up email": .email, "followup email": .email, "follow up e mail": .email, "follow up": .email,
        "email": .email, "e mail": .email, "draft email": .email,
    ]

    private static func kind(of heading: String) -> Kind? {
        let name = heading.lowercased().replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ":*_").union(.whitespaces))
        return kinds[name]
    }

    /// The text of a "#" to "######" heading, or of a line in bold that names a section.
    private static func headingText(_ line: String) -> String? {
        if line.hasPrefix("#") {
            let level = line.prefix { $0 == "#" }.count
            let rest = line.dropFirst(level)
            guard level <= 6, rest.first == " " else {
                return nil
            }
            var text = rest.trimmingCharacters(in: .whitespaces)
            // An optional closing run of #s, as in "## Summary ##".
            let closing = text.reversed().prefix { $0 == "#" }.count
            if closing > 0, text.dropLast(closing).last == " " {
                text = text.dropLast(closing).trimmingCharacters(in: .whitespaces)
            }
            return text.isEmpty ? nil : text
        }
        let bold = line.hasSuffix(":") ? String(line.dropLast()) : line
        guard bold.count > 4, bold.hasPrefix("**"), bold.hasSuffix("**") else {
            return nil
        }
        let inner = String(bold.dropFirst(2).dropLast(2))
        return !inner.contains("*") && kind(of: inner) != nil ? inner : nil
    }

    /// A list item's text without its "-", "*", "+", "•" or "1." marker, as part of
    /// `line`; nil for a line that is not a list item. A line starting with a checkbox is
    /// one too, marker or not.
    private static func listItem(_ line: Substring) -> Substring? {
        let line = line.drop(while: \.isWhitespace)
        guard let first = line.first else {
            return nil
        }
        if checkbox(line) != nil {
            return line
        }
        var rest: Substring
        if "-*+•".contains(first) {
            rest = line.dropFirst()
        } else {
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            rest = line.dropFirst(digits.count)
            guard (1...3).contains(digits.count), rest.first == "." || rest.first == ")" else {
                return nil
            }
            rest = rest.dropFirst()
        }
        guard rest.first?.isWhitespace == true else {
            return nil
        }
        return rest.drop(while: \.isWhitespace)
    }

    /// A "[ ]", "[x]" or "[X]" at the start of `text`, with where its mark is.
    private static func checkbox(_ text: Substring) -> (done: Bool, mark: String.Index, rest: Substring)? {
        let box = Array(text.prefix(3))
        guard box.count == 3, box[0] == "[", box[2] == "]", [" ", "x", "X"].contains(box[1]) else {
            return nil
        }
        return (box[1] != " ", text.index(after: text.startIndex), text.dropFirst(3).drop(while: \.isWhitespace))
    }

    private static func actionItem(_ item: Item) -> ActionItem {
        var text = Substring(item.text)
        var done = false
        if let box = checkbox(text) {
            done = box.done
            text = box.rest
        }
        let (owner, rest) = owner(of: text)
        return ActionItem(done: done, owner: owner, text: String(rest), line: item.line)
    }

    /// "**Me**: send it", "**Me:** send it" or "Me: send it" as "Me" and "send it".
    private static func owner(of text: Substring) -> (String?, Substring) {
        if text.hasPrefix("**"), let close = text.dropFirst(2).range(of: "**") {
            var owner = text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound]
            var rest = text[close.upperBound...]
            let separator = rest.drop(while: \.isWhitespace)
            if owner.hasSuffix(":") {
                owner = owner.dropLast()
            } else if let mark = separator.first, ":-\u{2013}\u{2014}".contains(mark) {
                rest = separator.dropFirst()
            } else {
                return (nil, text)
            }
            let name = owner.trimmingCharacters(in: .whitespaces)
            return name.isEmpty || name.count > 40 ? (nil, text) : (name, rest.drop(while: \.isWhitespace))
        }
        for name in ["Me", "Them"] where text.hasPrefix(name + ":") {
            return (name, text.dropFirst(name.count + 1).drop(while: \.isWhitespace))
        }
        return (nil, text)
    }

    private static func settingCheckbox(in line: String, done: Bool) -> String {
        var line = line
        let content = listItem(line[...]) ?? line.drop(while: \.isWhitespace)
        if let box = checkbox(content) {
            if box.done != done {
                line.replaceSubrange(box.mark...box.mark, with: done ? "x" : " ")
            }
        } else {
            line.insert(contentsOf: done ? "[x] " : "[ ] ", at: content.startIndex)
        }
        return line
    }

    /// A section's list items, or its paragraphs where it has no list. A line that is not
    /// an item carries on the one before it. "None recorded." and the like are dropped.
    private static func items(in lines: [Line]) -> [Item] {
        var items: [Item] = []
        var carriesOn = false
        for line in lines {
            let text = line.trimmed
            if text.isEmpty || isRule(text) {
                carriesOn = false
            } else if let item = listItem(text[...]) {
                items.append(Item(line: line.index, text: String(item)))
                carriesOn = true
            } else if carriesOn {
                items[items.count - 1].text += " " + text
            } else {
                items.append(Item(line: line.index, text: text))
                carriesOn = true
            }
        }
        return items.filter { !isNone($0.text) }
    }

    private static func email(in lines: [Line]) -> Email? {
        var lines = lines.map(\.trimmed)
        trimBlankLines(&lines)
        if lines.count >= 2, lines[0].hasPrefix("```"), lines[lines.count - 1].hasPrefix("```") {
            lines = Array(lines.dropFirst().dropLast())
            trimBlankLines(&lines)
        }
        if !lines.isEmpty, lines.allSatisfy({ $0.isEmpty || $0.hasPrefix(">") }) {
            lines = lines.map { $0.dropFirst().trimmingCharacters(in: .whitespaces) }
        }
        guard let first = lines.first, !(lines.count == 1 && isNone(first)) else {
            return nil
        }
        let subject = subject(in: first)
        if subject != nil {
            lines.removeFirst()
            trimBlankLines(&lines)
        }
        return Email(subject: subject, body: lines.joined(separator: "\n"))
    }

    /// "Subject: Delays", "**Subject:** Delays", "Subject line: Delays" and the like.
    private static func subject(in line: String) -> String? {
        var rest = line.drop { $0 == "*" || $0 == "_" }
        guard rest.lowercased().hasPrefix("subject") else {
            return nil
        }
        rest = rest.dropFirst("subject".count)
        if rest.lowercased().hasPrefix(" line") {
            rest = rest.dropFirst(" line".count)
        }
        let separator = rest.prefix { "*_: ".contains($0) }
        let subject = withoutEmphasis(String(rest.dropFirst(separator.count)))
        return separator.contains(":") && !subject.isEmpty ? subject : nil
    }

    /// "*Monday*" or "**Monday**" as "Monday".
    private static func withoutEmphasis(_ text: String) -> String {
        var text = Substring(text)
        for marker in ["**", "__", "*", "_"]
        where text.count > 2 * marker.count && text.hasPrefix(marker) && text.hasSuffix(marker) {
            text = text.dropFirst(marker.count).dropLast(marker.count)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// "None recorded.", "None.", "*Nothing agreed*": what a section with nothing in it says.
    private static func isNone(_ text: String) -> Bool {
        let words = withoutEmphasis(text).lowercased().trimmingCharacters(in: .punctuationCharacters)
            .split(separator: " ")
        return (words.count <= 3 && (words.first == "none" || words.first == "nothing")) || words == ["n/a"]
    }

    /// "---", "***" or "___" between parts of a section.
    private static func isRule(_ text: String) -> Bool {
        let marks = text.filter { $0 != " " }
        return marks.count >= 3 && Set(marks).count == 1 && "-*_".contains(marks.first!)
    }

    private static func text(of lines: [Line]) -> String {
        lines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimBlankLines(_ lines: inout [String]) {
        while lines.first?.isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
    }
}
