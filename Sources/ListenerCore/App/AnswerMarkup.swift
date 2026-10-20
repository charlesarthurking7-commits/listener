import Foundation

/// A run of answer text in one style.
public struct AnswerSpan: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        case plain
        case bold
        /// Written in [square brackets]: meant for the user only, not to be said aloud.
        case note
    }

    public var text: String
    public var style: Style

    public init(_ text: String, _ style: Style = .plain) {
        self.text = text
        self.style = style
    }
}

/// One line of an answer as the card lays it out.
public struct AnswerBlock: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case paragraph
        /// A list item with its marker, "•" or the item's number such as "2.".
        case bullet(String)
        /// A whole line in square brackets, shown apart from what to say.
        case note
    }

    /// The block's position in the answer. Blocks are only ever appended while an answer
    /// streams, so this stays the same for a block from its first word to the last.
    public let id: Int
    public let kind: Kind
    public let spans: [AnswerSpan]

    public init(id: Int, kind: Kind, spans: [AnswerSpan]) {
        self.id = id
        self.kind = kind
        self.spans = spans
    }

    public var text: String { spans.map(\.text).joined() }
}

/// The small part of Markdown that answers use (paragraphs, "-" and "1." lists, **bold**)
/// plus the prompt's convention of [square brackets] for notes meant only for the user.
///
/// Built for streaming: lines that have ended are parsed once and kept, and each update
/// only parses the line still being written. An unclosed "[" or "**" styles the rest of
/// the line, so text never changes style when the closing mark arrives.
public struct AnswerMarkup: Sendable, Equatable {
    public private(set) var blocks: [AnswerBlock] = []
    private var source = ""
    private var settledBlocks: [AnswerBlock] = []
    /// UTF-8 offset in `source` just past the last newline that has been parsed.
    private var settledEnd = 0

    public init() {}

    public init(_ text: String) {
        update(text)
    }

    public mutating func update(_ text: String) {
        if text == source {
            return
        }
        if !text.utf8.starts(with: source.utf8) {
            settledBlocks = []
            settledEnd = 0
        }
        source = text

        let utf8 = text.utf8
        var lineStart = utf8.index(utf8.startIndex, offsetBy: settledEnd)
        var index = lineStart
        while index != utf8.endIndex {
            if utf8[index] == UInt8(ascii: "\n") {
                appendLine(text[lineStart..<index], to: &settledBlocks)
                lineStart = utf8.index(after: index)
            }
            index = utf8.index(after: index)
        }
        settledEnd = utf8.distance(from: utf8.startIndex, to: lineStart)

        var all = settledBlocks
        appendLine(text[lineStart...], to: &all)
        blocks = all
    }

    /// What Copy puts on the clipboard: the words to say, without the notes or the
    /// Markdown marks, one line per paragraph or list item.
    public var textToSay: String {
        blocks.compactMap { block -> String? in
            // Taking a note out of a sentence leaves two spaces where it was.
            let words = block.spans.filter { $0.style != .note }.map(\.text).joined()
                .split(separator: " ").joined(separator: " ")
            switch block.kind {
            case .note:
                return nil
            case _ where words.isEmpty:
                return nil
            case .paragraph:
                return words
            case .bullet(let marker):
                return marker == "•" ? "- \(words)" : "\(marker) \(words)"
            }
        }.joined(separator: "\n")
    }

    private func appendLine(_ line: Substring, to blocks: inout [AnswerBlock]) {
        let trimmed = line.drop(while: \.isWhitespace)
        if trimmed.allSatisfy(\.isWhitespace) {
            return
        }
        let id = blocks.count
        if let content = Self.wholeLineNote(trimmed) {
            blocks.append(AnswerBlock(id: id, kind: .note, spans: [AnswerSpan(String(content), .note)]))
        } else if let item = Self.listItem(trimmed) {
            blocks.append(AnswerBlock(id: id, kind: .bullet(item.marker), spans: Self.spans(item.content)))
        } else if let heading = Self.heading(trimmed) {
            let spans = Self.spans(heading).map { AnswerSpan($0.text, $0.style == .note ? .note : .bold) }
            blocks.append(AnswerBlock(id: id, kind: .paragraph, spans: spans))
        } else {
            blocks.append(AnswerBlock(id: id, kind: .paragraph, spans: Self.spans(trimmed)))
        }
    }

    /// "[check the account first]" on a line of its own, or a line that opens a bracket
    /// that has not closed yet.
    private static func wholeLineNote(_ line: Substring) -> Substring? {
        guard line.first == "[" else {
            return nil
        }
        let body = line.dropFirst()
        guard let close = body.firstIndex(of: "]") else {
            return trimmingTrailingWhitespace(body)
        }
        if body[body.index(after: close)...].allSatisfy(\.isWhitespace) {
            return trimmingTrailingWhitespace(body[..<close])
        }
        return nil
    }

    private static func trimmingTrailingWhitespace(_ text: Substring) -> Substring {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        return text[..<end]
    }

    private static func listItem(_ line: Substring) -> (marker: String, content: Substring)? {
        if let first = line.first, "-*+•".contains(first), line.dropFirst().first == " " {
            return ("•", line.dropFirst(2))
        }
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else {
            return nil
        }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else {
            return nil
        }
        return ("\(digits).", rest.dropFirst(2))
    }

    private static func heading(_ line: Substring) -> Substring? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard !hashes.isEmpty, hashes.count <= 6, line.dropFirst(hashes.count).first == " " else {
            return nil
        }
        return line.dropFirst(hashes.count + 1)
    }

    /// Splits a line into plain, **bold** and [note] runs. A Markdown link keeps its
    /// text and drops the address.
    static func spans(_ line: Substring) -> [AnswerSpan] {
        var spans: [AnswerSpan] = []
        var current = ""
        var bold = false
        var note = false

        func flush() {
            if current.isEmpty {
                return
            }
            let style: AnswerSpan.Style = note ? .note : (bold ? .bold : .plain)
            if let last = spans.last, last.style == style {
                spans[spans.count - 1].text += current
            } else {
                spans.append(AnswerSpan(current, style))
            }
            current = ""
        }

        var index = line.startIndex
        while index != line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if character == "*", next != line.endIndex, line[next] == "*" {
                flush()
                bold.toggle()
                index = line.index(after: next)
                continue
            }
            if character == "[", !note {
                flush()
                note = true
            } else if character == "]", note {
                if next != line.endIndex, line[next] == "(", let close = line[next...].firstIndex(of: ")") {
                    // [text](address): the bracket was a link, not a note.
                    note = false
                    flush()
                    index = line.index(after: close)
                    continue
                }
                flush()
                note = false
            } else {
                current.append(character)
            }
            index = next
        }
        flush()
        return spans.map { span in
            span.style == .note ? AnswerSpan(span.text.trimmingCharacters(in: .whitespaces), .note) : span
        }.filter { !$0.text.isEmpty }
    }
}
