import Foundation

/// The readable parts of an HTML page: its title, its text without scripts, styles and
/// markup, and any schema.org JobPosting data, which job boards publish for search
/// engines even when the page itself is drawn by JavaScript.
public struct WebPageText: Sendable, Equatable {
    public var title: String?
    public var text: String
    public var jobPostingData: [String]

    /// Pages past this are cut before parsing; a job posting is a fraction of it.
    static let maxHTMLCharacters = 3_000_000
    static let maxDataCharacters = 20_000

    public init(html: String) {
        let html = String(html.prefix(Self.maxHTMLCharacters))
        let title = Self.captures(Self.titlePattern, in: html).first.map { Self.tidy(Self.decodingEntities($0)) }
        self.title = title?.isEmpty == false ? title : nil
        jobPostingData = Self.captures(Self.structuredDataPattern, in: html)
            .filter { $0.contains("JobPosting") }
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxDataCharacters)) }

        var body = Self.replacing(Self.hiddenPattern, in: html, with: " ")
        body = Self.replacing(Self.listItemPattern, in: body, with: "\n- ")
        body = Self.replacing(Self.blockPattern, in: body, with: "\n")
        body = Self.replacing(Self.tagPattern, in: body, with: "")
        text = Self.tidy(Self.decodingEntities(body))
    }

    private static let titlePattern = pattern("<title[^>]*>([\\s\\S]*?)</title>")
    private static let structuredDataPattern = pattern(
        "<script[^>]*application/ld\\+json[^>]*>([\\s\\S]*?)</script>")
    private static let hiddenPattern = pattern(
        "<(script|style|noscript|svg|template|head)\\b[\\s\\S]*?</\\1\\s*>|<!--[\\s\\S]*?-->")
    private static let listItemPattern = pattern("<li\\b[^>]*>")
    private static let blockPattern = pattern(
        "</?(p|div|br|h[1-6]|ul|ol|tr|table|section|article|header|footer|main|aside|nav|blockquote|pre|dl|dt|dd"
            + "|form|hr)\\b[^>]*>")
    private static let tagPattern = pattern("<[^>]+>")
    private static let entityPattern = pattern("&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "hellip": "…", "bull": "•", "pound": "£",
        "euro": "€", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
    ]

    private static func pattern(_ source: String) -> NSRegularExpression {
        // The patterns are constants, so a failure here is a typo caught by the tests.
        try! NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }

    private static func captures(_ pattern: NSRegularExpression, in text: String) -> [String] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func replacing(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func decodingEntities(_ text: String) -> String {
        var result = ""
        var last = text.startIndex
        for match in entityPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let name = Range(match.range(at: 1), in: text) else {
                continue
            }
            result += text[last..<whole.lowerBound]
            result += decoded(String(text[name])) ?? String(text[whole])
            last = whole.upperBound
        }
        return result + text[last...]
    }

    private static func decoded(_ entity: String) -> String? {
        guard entity.hasPrefix("#") else {
            return namedEntities[entity.lowercased()]
        }
        let digits = entity.dropFirst()
        let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }

    /// One space between words, no blank lines in a row, nothing at either end.
    private static func tidy(_ text: String) -> String {
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if words == "-" {
                words = ""
            }
            if words.isEmpty && (lines.last?.isEmpty ?? true) {
                continue
            }
            lines.append(words)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Turns a web page, usually a job posting, into a Markdown document for a call. The
/// quick model keeps the page's content in its own words and drops the navigation,
/// cookie notices and footers around it.
public struct WebPageImporter: Sendable {
    public struct Response: Sendable {
        public var body: Data
        public var status: Int
        public var mimeType: String?

        public init(body: Data, status: Int, mimeType: String?) {
            self.body = body
            self.status = status
            self.mimeType = mimeType
        }
    }

    public typealias Fetch = @Sendable (URL) async throws -> Response

    /// Less text than this, with no job posting data, is a page drawn by JavaScript or a
    /// sign-in wall.
    static let minimumCharacters = 200

    /// Ends a document the model stopped at its token limit, so answers don't take what
    /// is missing for something the page never said.
    static let cutShortNote = "[The rest of the page was cut off here.]"

    public var fetch: Fetch
    public var model: any LanguageModelProvider
    public var settings: ModelSettings

    public init(fetch: @escaping Fetch, model: any LanguageModelProvider, settings: ModelSettings) {
        self.fetch = fetch
        self.model = model
        self.settings = settings
    }

    /// The page as Markdown: its "# " title first and where it came from last.
    public func importPage(_ url: URL, now: Date = Date()) async throws -> String {
        let response = try await fetch(url)
        guard (200..<300).contains(response.status) else {
            throw WebPageImportError.status(response.status)
        }
        if let mimeType = response.mimeType?.lowercased(), !mimeType.contains("html"), !mimeType.hasPrefix("text/") {
            throw WebPageImportError.notAPage
        }
        let page = WebPageText(html: String(decoding: response.body, as: UTF8.self))
        guard page.text.count >= Self.minimumCharacters || !page.jobPostingData.isEmpty else {
            throw WebPageImportError.tooLittleText
        }

        var markdown = ""
        var cutShort = false
        for try await event in model.stream(PromptBuilder.webPageRequest(url: url, page: page, settings: settings)) {
            switch event {
            case .text(let text): markdown += text
            case .finished(_, let stopReason): cutShort = stopReason == "max_tokens"
            }
        }
        markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty, markdown != PromptBuilder.noContentReply else {
            throw WebPageImportError.noContent
        }
        if cutShort {
            markdown += "\n\n" + Self.cutShortNote
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMMM yyyy"
        return "\(markdown)\n\nSource: \(url.absoluteString), fetched \(formatter.string(from: now))\n"
    }
}

public enum WebPageImportError: Error, Equatable, CustomStringConvertible {
    case status(Int)
    case notAPage
    case tooLittleText
    case noContent

    public var description: String {
        let paste = "Copy the text from the page and press Paste instead."
        return switch self {
        case .status(let code):
            "The page could not be read (HTTP \(code)). Some sites, LinkedIn among them, need a sign-in. \(paste)"
        case .notAPage:
            "That link is not a web page Listener can read. \(paste)"
        case .tooLittleText:
            "The page has almost no text, probably because it is drawn by JavaScript. \(paste)"
        case .noContent:
            "Listener found nothing worth keeping on that page. \(paste)"
        }
    }
}
