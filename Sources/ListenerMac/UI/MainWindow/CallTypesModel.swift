import AppKit
import ListenerCore
import Observation

/// The Call types section: the folders under Call Types, edited in place. Text is saved
/// a moment after typing stops, and the folders are watched, so an edit in Finder or
/// another editor shows up here too.
@MainActor
@Observable
final class CallTypesModel {
    /// One of the files the user writes in the app, with the note Listener put at its
    /// top kept aside: it explains the file to someone opening it in TextEdit, and the
    /// app says the same next to the editor.
    enum Note: String, CaseIterable, Identifiable {
        case instructions
        case brief
        case stories

        var id: Self { self }

        var file: String {
            switch self {
            case .instructions: CallTypeLibrary.instructionsFile
            case .brief: CallTypeLibrary.briefFile
            case .stories: CallTypeLibrary.storiesFile
            }
        }

        var title: String {
            switch self {
            case .instructions: "How answers should go"
            case .brief: "Brief"
            case .stories: "Stories"
            }
        }
    }

    private(set) var names: [String] = []
    /// How many background files each call type has, for the list.
    private(set) var fileCounts: [String: Int] = [:]
    /// The call type on screen, which need not be the one the next call uses.
    private(set) var selected: String?
    private(set) var files: [LoadedCallType.File] = []
    private(set) var isReadingFiles = false
    private(set) var isImportingPage = false
    /// Text of instructions.md, brief.md and stories.md, without Listener's note.
    private(set) var texts: [Note: String] = [:]
    /// The latest problem, shown until the next action.
    var message: String?

    let call: CallModel
    private let library: CallTypeLibrary
    private let importWebPage: @Sendable (URL, Settings) async throws -> String
    @ObservationIgnored private var headers: [Note: String] = [:]
    @ObservationIgnored private var pendingSaves: [Note: Task<Void, Never>] = [:]
    @ObservationIgnored private let typesWatcher = FolderWatcher()
    @ObservationIgnored private let folderWatcher = FolderWatcher()
    @ObservationIgnored private var reads = 0

    init(call: CallModel, environment: AppEnvironment) {
        self.call = call
        library = CallTypeLibrary(paths: environment.paths)
        importWebPage = environment.importWebPage
    }

    /// How much of the background allowance the files use.
    var tokens: Int { files.reduce(0) { $0 + $1.tokens } }

    func refresh() {
        try? library.createIfMissing()
        names = library.names()
        countFiles()
        typesWatcher.watch(library.directory) { [weak self] in
            self?.namesChanged()
        }
        select(selected.flatMap { names.contains($0) ? $0 : nil } ?? call.callType)
    }

    func stopWatching() {
        saveNow()
        typesWatcher.stop()
        folderWatcher.stop()
    }

    func select(_ name: String) {
        guard names.contains(name) || name == call.callType else {
            return
        }
        saveNow()
        selected = name
        message = nil
        readTexts()
        folderWatcher.watch(library.folder(for: name)) { [weak self] in
            self?.folderChanged()
        }
        reloadFiles()
    }

    /// Changes one of the texts and saves it shortly, once typing has paused.
    func setText(_ text: String, for note: Note) {
        guard texts[note] != text else {
            return
        }
        texts[note] = text
        pendingSaves[note]?.cancel()
        pendingSaves[note] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else {
                return
            }
            self?.save(note)
            self?.pendingSaves[note] = nil
        }
    }

    func saveNow() {
        for note in pendingSaves.keys {
            pendingSaves[note]?.cancel()
            save(note)
        }
        pendingSaves.removeAll()
    }

    func useForNextCall() {
        guard let selected else {
            return
        }
        call.selectCallType(selected)
    }

    // MARK: Files

    func addFiles(_ urls: [URL]) {
        guard let selected else {
            return
        }
        let readable = urls.filter(DocumentText.canRead)
        message = readable.count < urls.count ? "Listener reads \(DocumentText.kinds). Other files were left out." : nil
        guard !readable.isEmpty else {
            return
        }
        do {
            try library.add(files: readable, to: selected)
        } catch {
            message = "Could not add the files: \(ErrorText.describe(error))"
        }
        reloadFiles()
    }

    /// Asks for files to add, in a sheet on the main window.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "Listener reads \(DocumentText.kinds)."
        guard panel.runModal() == .OK else {
            return
        }
        addFiles(panel.urls)
    }

    /// Adds whatever is on the clipboard: copied files, a link to read, or text.
    func paste() {
        guard let selected else {
            return
        }
        let pasteboard = NSPasteboard.general
        let copied = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        if let copied = copied as? [URL], !copied.isEmpty {
            addFiles(copied)
            return
        }
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            message = "The clipboard is empty. Copy some text, or a link, then paste."
            return
        }
        if !text.contains(where: \.isWhitespace), let url = URL(string: text),
            ["http", "https"].contains(url.scheme?.lowercased())
        {
            importPage(url, into: selected)
            return
        }
        do {
            try library.add(text: text, to: selected)
            message = nil
        } catch {
            message = "Could not save the pasted text: \(ErrorText.describe(error))"
        }
        reloadFiles()
    }

    func open(_ file: LoadedCallType.File) {
        NSWorkspace.shared.open(file.url)
    }

    func reveal(_ file: LoadedCallType.File) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    /// Moves a file to the Bin, so a mistake can be undone in Finder.
    func remove(_ file: LoadedCallType.File) {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
        } catch {
            message = "Could not move \(file.url.lastPathComponent) to the Bin: \(ErrorText.describe(error))"
        }
        reloadFiles()
    }

    // MARK: Call types

    /// Makes a new, empty call type and shows it.
    func create() {
        let name = unusedName("New call type")
        do {
            let folder = library.folder(for: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(CallTypeLibrary.instructionsHeader.utf8)
                .write(
                    to: folder.appendingPathComponent(CallTypeLibrary.instructionsFile), options: .withoutOverwriting)
        } catch {
            message = "Could not create the call type: \(ErrorText.describe(error))"
            return
        }
        namesChanged()
        select(name)
    }

    func duplicate() {
        guard let selected else {
            return
        }
        saveNow()
        let name = unusedName("\(selected) copy")
        do {
            try FileManager.default.copyItem(at: library.folder(for: selected), to: library.folder(for: name))
        } catch {
            message = "Could not duplicate \(selected): \(ErrorText.describe(error))"
            return
        }
        namesChanged()
        select(name)
    }

    /// Renames the folder, and keeps the next call on it if it was picked.
    func rename(to newName: String) {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selected, newName != selected else {
            return
        }
        guard !newName.isEmpty, !newName.contains("/"), !newName.hasPrefix(".") else {
            message = "A call type's name can't be empty, start with a dot or contain a slash."
            return
        }
        guard !names.contains(newName) else {
            message = "There is already a call type called \(newName)."
            return
        }
        saveNow()
        let wasNext = call.callType == selected
        do {
            try FileManager.default.moveItem(at: library.folder(for: selected), to: library.folder(for: newName))
        } catch {
            message = "Could not rename \(selected): \(ErrorText.describe(error))"
            return
        }
        self.selected = newName
        call.refreshCallTypes()
        if wasNext {
            call.selectCallType(newName)
        }
        namesChanged()
        select(newName)
    }

    /// Moves the call type's folder to the Bin, after asking.
    func delete() {
        guard let selected else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Move \(selected) to the Bin?"
        alert.informativeText =
            "Its instructions, brief, stories and files go with it. You can put it back from the Bin."
        alert.addButton(withTitle: "Move to Bin")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        for save in pendingSaves.values {
            save.cancel()
        }
        pendingSaves.removeAll()
        do {
            try FileManager.default.trashItem(at: library.folder(for: selected), resultingItemURL: nil)
        } catch {
            message = "Could not move \(selected) to the Bin: \(ErrorText.describe(error))"
            return
        }
        self.selected = nil
        call.refreshCallTypes()
        namesChanged()
        select(names.first(where: { $0 == call.callType }) ?? names.first ?? CallTypeLibrary.defaultType)
    }

    func revealInFinder() {
        guard let selected else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([library.folder(for: selected)])
    }

    // MARK: Reading and saving

    private func namesChanged() {
        names = library.names()
        countFiles()
        if let selected, !names.contains(selected) {
            self.selected = nil
            select(names.first(where: { $0 == call.callType }) ?? names.first ?? CallTypeLibrary.defaultType)
        }
        call.refreshCallTypes()
    }

    /// Something in the folder changed: a file added in Finder, or a note saved in
    /// another editor. Notes being typed here are left alone.
    private func folderChanged() {
        for note in Note.allCases where pendingSaves[note] == nil {
            let (header, body) = Self.read(note, in: folderURL)
            if body != texts[note] {
                texts[note] = body
                headers[note] = header
            }
        }
        reloadFiles()
    }

    private func countFiles() {
        fileCounts = Dictionary(uniqueKeysWithValues: names.map { ($0, library.documentFiles(of: $0).count) })
    }

    private var folderURL: URL? {
        selected.map(library.folder(for:))
    }

    private func readTexts() {
        for note in Note.allCases {
            let (header, body) = Self.read(note, in: folderURL)
            texts[note] = body
            headers[note] = header
        }
    }

    private func save(_ note: Note) {
        guard let folder = folderURL, let text = texts[note] else {
            return
        }
        let url = folder.appendingPathComponent(note.file)
        let exists = FileManager.default.fileExists(atPath: url.path)
        // An empty brief or stories file that never existed stays absent.
        guard exists || !text.isEmpty else {
            return
        }
        let header = headers[note] ?? Self.template(for: note)
        do {
            try Data((header + text).utf8).write(to: url, options: .atomic)
            headers[note] = header
        } catch {
            message = "Could not save \(note.file): \(ErrorText.describe(error))"
        }
    }

    /// A file's leading <!-- note -->, if it has one, and the text after it.
    private static func read(_ note: Note, in folder: URL?) -> (header: String?, body: String) {
        guard let folder, let text = try? CallTypeLibrary.readPlainText(folder.appendingPathComponent(note.file))
        else {
            return (nil, "")
        }
        guard text.hasPrefix("<!--"), let end = text.range(of: "-->") else {
            return ("", text)
        }
        var bodyStart = end.upperBound
        while bodyStart < text.endIndex, text[bodyStart].isNewline {
            bodyStart = text.index(after: bodyStart)
        }
        return (String(text[..<bodyStart]), String(text[bodyStart...]))
    }

    private static func template(for note: Note) -> String {
        switch note {
        case .instructions: CallTypeLibrary.instructionsHeader
        case .brief: CallTypeLibrary.briefTemplate
        case .stories: CallTypeLibrary.storiesTemplate
        }
    }

    /// Reads the files off the main thread: a long PDF takes a moment.
    private func reloadFiles() {
        guard let name = selected else {
            files = []
            return
        }
        let library = library
        reads += 1
        let read = reads
        isReadingFiles = true
        Task {
            let loaded = await Task.detached { library.load(name, readText: DocumentText.read) }.value
            if selected == name, read == reads {
                files = loaded.files
                fileCounts[name] = loaded.files.count
                isReadingFiles = false
            }
        }
    }

    private func importPage(_ url: URL, into name: String) {
        guard !isImportingPage else {
            return
        }
        isImportingPage = true
        message = nil
        let settings = call.settings
        let importWebPage = importWebPage
        Task {
            do {
                let markdown = try await importWebPage(url, settings)
                try library.add(text: markdown, to: name)
            } catch {
                Log.ui.notice("Reading \(url.host() ?? "a link", privacy: .public) failed")
                message = ErrorText.describe(error)
            }
            isImportingPage = false
            reloadFiles()
        }
    }

    private func unusedName(_ base: String) -> String {
        var name = base
        var number = 2
        while FileManager.default.fileExists(atPath: library.folder(for: name).path) {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }
}
