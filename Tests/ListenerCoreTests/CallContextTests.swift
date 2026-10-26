import Foundation
import Testing

@testable import ListenerCore

final class CallTypeLibraryTests {
    private let directory: URL
    private let library: CallTypeLibrary

    init() throws {
        directory = try temporaryDirectory("call-types")
        library = CallTypeLibrary(directory: directory.appendingPathComponent("Call Types"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    @Test func theBuiltInTypesAreCreatedOnceAndDeletionsStick() throws {
        try library.createIfMissing()
        #expect(library.names() == ["Meeting", "Work call"])
        let meeting = library.load("Meeting")
        #expect(meeting.context.instructions.hasPrefix("A meeting where Me mostly listens."))
        #expect(!meeting.context.instructions.contains("<!--"))

        try FileManager.default.removeItem(at: library.folder(for: "Meeting"))
        try library.createIfMissing()
        #expect(library.names() == ["Work call"])
    }

    @Test func documentsComeBriefAndStoriesFirstWithoutTheirComments() throws {
        try library.createIfMissing()
        let folder = library.folder(for: "Work call")
        try write("Acme runs three MT5 servers.", to: folder.appendingPathComponent("acme servers.md"))
        try write("Restart the bridge before the open.", to: folder.appendingPathComponent("Runbook.txt"))
        try write("<!-- a note to myself -->\nThe call is with Sam and Priya.", to: library.briefFile(for: "Work call"))
        try write("## The late fills\nGood for: incidents", to: library.storiesFile(for: "Work call"))
        try write("hidden", to: folder.appendingPathComponent(".DS_Store"))

        let loaded = library.load("Work call")
        #expect(loaded.context.callType == "Work call")
        #expect(loaded.context.documents.map(\.name) == ["Brief", "Stories", "acme servers.md", "Runbook.txt"])
        #expect(loaded.context.documents[0].text == "The call is with Sam and Priya.")
        #expect(loaded.files.allSatisfy { $0.problem == nil && $0.tokens > 0 })
    }

    @Test func aNewStoriesFileIsOnlyItsNoteUntilFilledIn() throws {
        let url = try library.createStoriesIfMissing(for: "Work call")
        #expect(try CallTypeLibrary.readPlainText(url).contains("Good for:"))
        #expect(library.load("Work call").files.map(\.problem) == ["Empty"])

        try write("## The late fills\nGood for: incidents", to: url)
        try library.createStoriesIfMissing(for: "Work call")
        #expect(library.load("Work call").context.documents.map(\.text) == ["## The late fills\nGood for: incidents"])
    }

    @Test func emptyAndUnreadableFilesAreShownButNotSent() throws {
        try library.createBriefIfMissing(for: "Work call")
        try write("scan", to: library.folder(for: "Work call").appendingPathComponent("scan.pdf"))

        let loaded = library.load("Work call") { url in
            if url.pathExtension == "pdf" {
                return ""
            }
            return try CallTypeLibrary.readPlainText(url)
        }
        #expect(loaded.context.documents.isEmpty)
        #expect(loaded.files.map(\.problem) == ["Empty", "No text found"])

        let failing = library.load("Work call") { _ in throw CocoaError(.fileReadCorruptFile) }
        #expect(failing.files.map(\.problem) == ["Can't be read", "Can't be read"])
    }

    @Test func backgroundOverTheBudgetIsCutThenLeftOut() throws {
        let folder = library.folder(for: "Work call")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let budgetBytes = CallTypeLibrary.documentBudgetTokens * TokenEstimate.bytesPerToken
        try write(String(repeating: "a", count: budgetBytes / 2), to: folder.appendingPathComponent("a.txt"))
        try write(String(repeating: "b", count: budgetBytes), to: folder.appendingPathComponent("b.txt"))
        try write("c", to: folder.appendingPathComponent("c.txt"))

        let loaded = library.load("Work call")
        #expect(loaded.files.map(\.problem) == [nil, "Cut to fit", "Left out"])
        #expect(loaded.context.documents.map(\.name) == ["a.txt", "b.txt"])
        #expect(loaded.files.reduce(0) { $0 + $1.tokens } <= CallTypeLibrary.documentBudgetTokens)
    }

    @Test func addedFilesAndTextNeverOverwrite() throws {
        let source = directory.appendingPathComponent("runbook.pdf")
        try write("pdf", to: source)

        let added = try library.add(files: [source, source], to: "Work call")
        #expect(added.map(\.lastPathComponent) == ["runbook.pdf", "runbook 2.pdf"])
        #expect(try library.add(files: [added[0]], to: "Work call") == [added[0]])

        let pasted = try library.add(text: "# Bridge Upgrade: Acme / London\n\nThe plan.", to: "Work call")
        #expect(pasted.lastPathComponent == "Bridge Upgrade Acme London.md")
        #expect(try library.add(text: "   \n", to: "Work call").lastPathComponent == "Pasted text.md")
        #expect(try CallTypeLibrary.readPlainText(pasted).hasSuffix("The plan."))
    }
}

struct WebPageTextTests {
    @Test func keepsTheReadableTextAndDropsTheRest() {
        let page = WebPageText(
            html: """
                <html><head><title>Ops Engineer &amp; Analyst | Acme</title><style>p { color: red }</style></head>
                <body><nav>Home</nav><script>track()</script><!-- tracking -->
                <h1>Ops&nbsp;Engineer</h1><p>Join   our <b>trading</b> team.</p>
                <ul><li>Five years&#39; experience</li><li>Python &#x26; SQL</li></ul></body></html>
                """)
        #expect(page.title == "Ops Engineer & Analyst | Acme")
        #expect(
            page.text == "Home\n\nOps Engineer\n\nJoin our trading team.\n\n- Five years' experience\n- Python & SQL")
        #expect(page.jobPostingData.isEmpty)
    }

    @Test func keepsJobPostingStructuredData() {
        let page = WebPageText(
            html: """
                <script type="application/ld+json">{"@type": "Organization", "name": "Acme"}</script>
                <script type="application/ld+json"> {"@type": "JobPosting", "title": "Ops Engineer"} </script>
                <div id="app"></div>
                """)
        #expect(page.jobPostingData == [#"{"@type": "JobPosting", "title": "Ops Engineer"}"#])
        #expect(page.text.isEmpty && page.title == nil)
    }
}

struct WebPageImporterTests {
    private let url = URL(string: "https://jobs.example.com/ops")!
    private let posting = "<h1>Ops Engineer</h1><p>\(String(repeating: "Run the trading platform. ", count: 20))</p>"

    private func importer(
        status: Int = 200, mimeType: String? = "text/html", html: String? = nil, reply: String = "# Ops Engineer, Acme"
    ) -> (WebPageImporter, ScriptedLanguageModel) {
        let body = Data((html ?? posting).utf8)
        let model = ScriptedLanguageModel(answer: reply, firstTokenDelay: .zero, tokenInterval: .zero)
        let importer = WebPageImporter(
            fetch: { _ in WebPageImporter.Response(body: body, status: status, mimeType: mimeType) }, model: model,
            settings: AnswerSettings().webPageImport)
        return (importer, model)
    }

    @Test func aPageCutOffAtTheTokenLimitSaysSo() async throws {
        let model = ScriptedLanguageModel(
            answer: "# Ops Engineer, Acme\n\nRun the", firstTokenDelay: .zero, tokenInterval: .zero,
            stopReason: "max_tokens")
        let body = Data(posting.utf8)
        let importer = WebPageImporter(
            fetch: { _ in WebPageImporter.Response(body: body, status: 200, mimeType: "text/html") }, model: model,
            settings: AnswerSettings().webPageImport)
        let markdown = try await importer.importPage(url)
        #expect(markdown.hasPrefix("# Ops Engineer, Acme\n\nRun the\n\n\(WebPageImporter.cutShortNote)\n\nSource: "))
    }

    @Test func aPostingBecomesMarkdownWithItsSource() async throws {
        let (importer, model) = importer()
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z"))
        let markdown = try await importer.importPage(url, now: date)
        #expect(markdown == "# Ops Engineer, Acme\n\nSource: https://jobs.example.com/ops, fetched 21 October 2026\n")
        let request = try #require(model.requests.first)
        #expect(request.settings == AnswerSettings().webPageImport)
        #expect(request.userText.contains("<page>\nOps Engineer\n\nRun the trading platform."))
        #expect(request.system.contains("reply with exactly NO_CONTENT"))
    }

    @Test func pagesThatCannotBeUsedSaySo() async {
        await #expect(throws: WebPageImportError.status(403)) { try await importer(status: 403).0.importPage(url) }
        await #expect(throws: WebPageImportError.notAPage) {
            try await importer(mimeType: "application/pdf").0.importPage(url)
        }
        await #expect(throws: WebPageImportError.tooLittleText) {
            try await importer(html: "<div id=\"app\"></div>").0.importPage(url)
        }
        await #expect(throws: WebPageImportError.noContent) {
            try await importer(reply: "NO_CONTENT").0.importPage(url)
        }
        #expect(WebPageImportError.status(999).description.hasSuffix("press Paste instead."))
    }
}
