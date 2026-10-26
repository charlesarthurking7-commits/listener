/// Tidied dictation as HTML, so apps that take formatted text paste its lists as real
/// lists. Plain text with "- " and "1." lines stays on the clipboard beside it, for the
/// apps that don't.
///
/// Only text with a list gets HTML: anything else pastes as plain text and so takes on
/// the font and style already at the cursor. Lines become divs and blank lines empty
/// ones, as mail and chat apps write them themselves, so the layout matches the plain
/// text exactly apart from the lists. No fonts or colours are set.
public enum DictationFormatting {
    public enum Block: Sendable, Equatable {
        case line(String)
        case blank
        /// `start` is the first item's number when `numbered`.
        case list(numbered: Bool, start: Int, items: [String])
    }

    /// The text as lines and lists, or nil when it has no list and so stays plain.
    public static func blocks(for text: String) -> [Block]? {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(
            separator: "\n", omittingEmptySubsequences: false
        ).map(String.init)
        guard lines.contains(where: { ListLine($0) != nil }) else {
            return nil
        }
        var blocks: [Block] = []
        for line in lines {
            guard let item = ListLine(line) else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                blocks.append(trimmed.isEmpty ? .blank : .line(trimmed))
                continue
            }
            let numbered = item.kind == .numbered
            if case .list(numbered, let start, let items) = blocks.last {
                blocks[blocks.count - 1] = .list(numbered: numbered, start: start, items: items + [item.text])
            } else {
                blocks.append(.list(numbered: numbered, start: max(item.number, 1), items: [item.text]))
            }
        }
        return blocks
    }

    public static func html(for text: String) -> String? {
        blocks(for: text).map(html)
    }

    public static func html(_ blocks: [Block]) -> String {
        var html = "<meta charset=\"utf-8\">"
        for block in blocks {
            switch block {
            case .line(let line):
                html += "<div>\(escaped(line))</div>"
            case .blank:
                html += "<div><br></div>"
            case .list(let numbered, let start, let items):
                let tag = numbered ? "ol" : "ul"
                html += numbered && start != 1 ? "<ol start=\"\(start)\">" : "<\(tag)>"
                html += items.map { "<li>\(escaped($0))</li>" }.joined()
                html += "</\(tag)>"
            }
        }
        return html
    }

    private static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    /// "- item", "• item", "* item" or "3. item", indented or not.
    private struct ListLine {
        enum Kind {
            case bullet
            case numbered
        }

        let kind: Kind
        let number: Int
        let text: String

        init?(_ line: String) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            for marker in ["- ", "• ", "* "] where trimmed.hasPrefix(marker) {
                kind = .bullet
                number = 0
                text = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                if text.isEmpty {
                    return nil
                }
                return
            }
            let digits = trimmed.prefix(while: \.isNumber)
            let rest = trimmed.dropFirst(digits.count)
            guard !digits.isEmpty, digits.count <= 3, rest.hasPrefix(". ") || rest.hasPrefix(") "),
                let number = Int(digits)
            else {
                return nil
            }
            kind = .numbered
            self.number = number
            text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                return nil
            }
        }
    }
}
