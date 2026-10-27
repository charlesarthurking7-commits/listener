import Foundation

/// The kinds of call to pick from before Start, one folder each under Call Types.
/// instructions.md says how answers should go on that kind of call, and every other file
/// in the folder (a PDF, a saved web page, brief.md, stories.md) is background that Claude
/// reads with each answer. They are plain files, editable in any app, and read again at every Start.
public struct CallTypeLibrary: Sendable {
    public static let instructionsFile = "instructions.md"
    public static let briefFile = "brief.md"
    /// The user's STAR stories, for "tell me about a time" questions.
    public static let storiesFile = "stories.md"
    public static let defaultType = "Work call"
    /// Background past this is cut, so one long PDF cannot make every answer slow and costly.
    public static let documentBudgetTokens = 20_000
    public static let budgetNote = "Listener sends up to \(documentBudgetTokens / 1000)k tokens of background per call."

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(paths: ListenerPaths) {
        self.init(directory: paths.supportDirectory.appendingPathComponent("Call Types", isDirectory: true))
    }

    /// Creates the folder with the built-in call types the first time. After that the
    /// folders are the user's, deletions included.
    public func createIfMissing() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        for type in Self.builtIn {
            let folder = folder(for: type.name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data((Self.instructionsHeader + type.instructions).utf8)
                .write(to: folder.appendingPathComponent(Self.instructionsFile), options: .atomic)
        }
    }

    /// The call types, alphabetically.
    public func names() -> [String] {
        contents(of: directory).filter(Self.isDirectory).map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func folder(for name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: true)
    }

    /// A call type's background files: everything but instructions.md, folders and hidden
    /// files. The brief and the stories come first, so a long PDF is what gets cut.
    public func documentFiles(of name: String) -> [URL] {
        func rank(_ url: URL) -> Int {
            switch url.lastPathComponent {
            case Self.briefFile: 0
            case Self.storiesFile: 1
            default: 2
            }
        }
        return contents(of: folder(for: name))
            .filter { $0.lastPathComponent != Self.instructionsFile && !Self.isDirectory($0) }
            .sorted { first, second in
                if rank(first) != rank(second) {
                    return rank(first) < rank(second)
                }
                return first.lastPathComponent.localizedStandardCompare(second.lastPathComponent) == .orderedAscending
            }
    }

    /// Reads a call type for a call. `readText` turns a file into plain text; the app's
    /// also reads PDF and Word documents.
    public func load(_ name: String, readText: (URL) throws -> String = Self.readPlainText) -> LoadedCallType {
        let instructionsURL = folder(for: name).appendingPathComponent(Self.instructionsFile)
        let instructions = (try? Self.readPlainText(instructionsURL)).map(Self.withoutComments) ?? ""
        var documents: [CallContext.Document] = []
        var files: [LoadedCallType.File] = []
        var budget = Self.documentBudgetTokens
        for url in documentFiles(of: name) {
            let ownNotes = Self.ownNotesTitles[url.lastPathComponent]
            let title = ownNotes ?? url.lastPathComponent
            guard let read = try? readText(url) else {
                files.append(LoadedCallType.File(url: url, name: title, tokens: 0, problem: "Can't be read"))
                continue
            }
            var text = Self.withoutComments(read)
            guard !text.isEmpty else {
                files.append(
                    LoadedCallType.File(
                        url: url, name: title, tokens: 0, problem: ownNotes != nil ? "Empty" : "No text found"))
                continue
            }
            var tokens = TokenEstimate.tokens(in: text)
            var problem: String?
            if budget == 0 {
                files.append(LoadedCallType.File(url: url, name: title, tokens: 0, problem: "Left out"))
                continue
            }
            if tokens > budget {
                text = String(text.prefix(budget * TokenEstimate.bytesPerToken))
                tokens = TokenEstimate.tokens(in: text)
                problem = "Cut to fit"
            }
            budget = max(0, budget - tokens)
            documents.append(CallContext.Document(name: title, text: text))
            files.append(LoadedCallType.File(url: url, name: title, tokens: tokens, problem: problem))
        }
        return LoadedCallType(
            context: CallContext(callType: name, instructions: instructions, documents: documents), files: files)
    }

    /// Copies files into a call type's folder. A name already taken gets a number, so
    /// nothing is overwritten. Files already in the folder are left where they are.
    @discardableResult
    public func add(files: [URL], to name: String) throws -> [URL] {
        let folder = folder(for: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try files.map { source in
            if source.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                return source
            }
            let target = Self.unusedURL(in: folder, for: source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }
    }

    /// Saves pasted or fetched text as a Markdown file named after its first line.
    @discardableResult
    public func add(text: String, to name: String) throws -> URL {
        let folder = folder(for: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = Self.unusedURL(in: folder, for: Self.fileName(forText: text) + ".md")
        try Data(text.utf8).write(to: target, options: .withoutOverwriting)
        return target
    }

    /// Creates brief.md with a note on what to put in it, unless it exists.
    @discardableResult
    public func createBriefIfMissing(for name: String) throws -> URL {
        try createIfMissing(Self.briefFile, for: name, template: Self.briefTemplate)
    }

    /// Creates stories.md with a note and an example layout, unless it exists.
    @discardableResult
    public func createStoriesIfMissing(for name: String) throws -> URL {
        try createIfMissing(Self.storiesFile, for: name, template: Self.storiesTemplate)
    }

    private func createIfMissing(_ file: String, for name: String, template: String) throws -> URL {
        let folder = folder(for: name)
        let url = folder.appendingPathComponent(file)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(template.utf8).write(to: url, options: .withoutOverwriting)
        }
        return url
    }

    public static func readPlainText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// The text without its <!-- comments -->, which are notes to the user, not to Claude.
    static func withoutComments(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return commentPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A file name from the text's first line, e.g. "Senior Operations Engineer, Acme".
    static func fileName(forText text: String) -> String {
        let firstLine =
            text.split(whereSeparator: \.isNewline)
            .first { !$0.allSatisfy(\.isWhitespace) }
            .map(String.init) ?? ""
        let cleaned = firstLine.drop { $0 == "#" || $0.isWhitespace }
            .filter { !"/\\:?*\"<>|".contains($0) }
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let name = String(cleaned.prefix(60)).trimmingCharacters(
            in: .whitespaces.union(CharacterSet(charactersIn: ".,;-")))
        return name.isEmpty ? "Pasted text" : name
    }

    /// The files Listener creates for the user's own notes, and the names they go by.
    private static let ownNotesTitles = [briefFile: "Brief", storiesFile: "Stories"]

    private static let commentPattern = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->")

    private static func unusedURL(in folder: URL, for fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let pathExtension = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = "\(base) \(number)"
            candidate = folder.appendingPathComponent(
                pathExtension.isEmpty ? numbered : "\(numbered).\(pathExtension)")
            number += 1
        }
        return candidate
    }

    private func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// A call type as read at Start: what goes to Claude, and what the window shows about
/// each file.
public struct LoadedCallType: Sendable, Equatable {
    public struct File: Sendable, Equatable, Identifiable {
        public var url: URL
        /// "Brief" for brief.md, otherwise the file name.
        public var name: String
        /// What Claude gets of it; 0 when it is left out.
        public var tokens: Int
        /// Why the file is left out or cut short, e.g. it has no text.
        public var problem: String?

        public var id: URL { url }
    }

    public var context: CallContext
    public var files: [File]
}

extension CallTypeLibrary {
    public static let instructionsHeader = """
        <!--
        How answers should go on this kind of call. Everything outside these comment marks goes
        to Claude with every answer, recap and summary, and wins over Listener's general rules
        where they differ. The other files in this folder are background for the call: drop
        files onto the Listener window, or copy some text or a link and press Paste. brief.md
        is for your own notes, and stories.md (Edit Stories in the card's menu) for your
        stories for "tell me about a time" questions.
        -->

        """

    public static let briefTemplate = """
        <!--
        Notes for your next call of this kind: who it is with, what it is for, and anything
        Listener should know. Everything outside these comment marks goes to Claude with every
        answer. Save the file and Listener picks it up.
        -->

        """

    public static let storiesTemplate = """
        <!--
        Your stories for "tell me about a time" questions, one block per story: a heading with
        a short name, a "Good for:" line with the kinds of question it answers, then the four
        points. The "Good for:" line is what picks the right story mid-call, and only real
        numbers belong here. Everything outside these comment marks goes to Claude with every
        answer. Save the file and Listener picks it up at the next Start.

        ## A short name for the story
        Good for: incidents, working under pressure, problem solving
        - Situation: what was going on
        - Task: what you had to do
        - Action: what you did
        - Result: what changed, with the numbers
        -->

        """

    static let builtIn: [(name: String, instructions: String)] = [
        (
            "Work call",
            """
            A work call with colleagues, clients or partners. The general rules apply as they are.

            """
        ),
        (
            "Meeting",
            """
            A meeting where Me mostly listens.

            - If nothing has been asked of Me, give only the note, with no line to chip in.
            - When Me is asked something, keep the answer to one or two sentences.

            In a recap, put decisions and actions first.

            """
        ),
    ]
}
