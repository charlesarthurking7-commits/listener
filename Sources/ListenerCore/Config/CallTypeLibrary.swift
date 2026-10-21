import Foundation

/// The kinds of call to pick from before Start, one folder each under Call Types.
/// instructions.md says how answers should go on that kind of call, and every other file
/// in the folder (a CV, a job description, brief.md) is background that Claude reads with
/// each answer. They are plain files, editable in any app, and read again at every Start.
public struct CallTypeLibrary: Sendable {
    public static let instructionsFile = "instructions.md"
    public static let briefFile = "brief.md"
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

    public func briefFile(for name: String) -> URL {
        folder(for: name).appendingPathComponent(Self.briefFile)
    }

    /// A call type's background files: everything but instructions.md, folders and hidden
    /// files, the brief first and the rest by name.
    public func documentFiles(of name: String) -> [URL] {
        contents(of: folder(for: name))
            .filter { $0.lastPathComponent != Self.instructionsFile && !Self.isDirectory($0) }
            .sorted { first, second in
                let firstIsBrief = first.lastPathComponent == Self.briefFile
                if firstIsBrief != (second.lastPathComponent == Self.briefFile) {
                    return firstIsBrief
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
            let isBrief = url.lastPathComponent == Self.briefFile
            let title = isBrief ? "Brief" : url.lastPathComponent
            guard let read = try? readText(url) else {
                files.append(LoadedCallType.File(url: url, name: title, tokens: 0, problem: "Can't be read"))
                continue
            }
            var text = Self.withoutComments(read)
            guard !text.isEmpty else {
                files.append(
                    LoadedCallType.File(url: url, name: title, tokens: 0, problem: isBrief ? "Empty" : "No text found"))
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
        let url = briefFile(for: name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: folder(for: name), withIntermediateDirectories: true)
            try Data(Self.briefTemplate.utf8).write(to: url, options: .withoutOverwriting)
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
    static let instructionsHeader = """
        <!--
        How answers should go on this kind of call. Everything outside these comment marks goes
        to Claude with every answer, recap and summary, and wins over Listener's general rules
        where they differ. The other files in this folder are background for the call: drop a
        CV or other files onto the Listener window, or copy a job description or its link and
        press Paste. brief.md is for your own notes.
        -->

        """

    static let briefTemplate = """
        <!--
        Notes for your next call of this kind: who it is with, what it is for, and anything
        Listener should know. Everything outside these comment marks goes to Claude with every
        answer. Save the file and Listener picks it up.
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
