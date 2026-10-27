import AppKit
import ListenerCore
import Observation

/// The Dictionary section: the spellings dictation uses. Words learned from corrections
/// and words added here are kept in dictionary.txt; words listed in settings.json's
/// dictation.vocabulary show alongside them.
@MainActor
@Observable
final class DictionaryModel {
    enum Source {
        /// Learned from a correction, with what it was heard as.
        case learned
        /// Added here, or by hand to dictionary.txt.
        case added
        /// In settings.json's dictation.vocabulary.
        case settings
    }

    struct Word: Identifiable {
        var term: String
        var heardAs: [String]
        var source: Source
        var id: String { "\(source)\u{0}\(term)" }
    }

    enum Filter: Hashable {
        case all
        case learned
        case added
    }

    private(set) var words: [Word] = []
    var filter = Filter.all
    var query = ""
    var message: String?

    let store: SettingsStore
    private let dictation: DictationController
    private let file: URL
    @ObservationIgnored private let watcher = FolderWatcher()

    init(dictation: DictationController, store: SettingsStore, environment: AppEnvironment) {
        self.dictation = dictation
        self.store = store
        file = environment.paths.dictionaryFile
    }

    var shown: [Word] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return words.filter { word in
            switch filter {
            case .all: true
            case .learned: word.source == .learned
            case .added: word.source != .learned
            }
        }
        .filter {
            query.isEmpty || $0.term.localizedStandardContains(query)
                || $0.heardAs.contains { $0.localizedStandardContains(query) }
        }
    }

    var learnedCount: Int { words.filter { $0.source == .learned }.count }

    func refresh() {
        store.reload()
        watcher.watch(file.deletingLastPathComponent()) { [weak self] in
            self?.read()
        }
        read()
    }

    func stopWatching() {
        watcher.stop()
    }

    /// Adds a word to spell exactly as typed. Several, separated by commas, are fine.
    func add(_ text: String) {
        var dictionary = load()
        var added = false
        for term in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !term.isEmpty {
            added = dictionary.add(term) || added
        }
        guard added else {
            message = "That word is already in the dictionary."
            return
        }
        save(dictionary)
    }

    func remove(_ word: Word) {
        switch word.source {
        case .learned, .added:
            var dictionary = load()
            dictionary.forget(word.term)
            save(dictionary)
        case .settings:
            store.set(store.settings.dictation.vocabulary.filter { $0 != word.term }, at: "dictation.vocabulary")
            read()
        }
    }

    func openFile() {
        dictation.openDictionary()
    }

    private func read() {
        let learned = load().entries.map { entry in
            Word(term: entry.term, heardAs: entry.heardAs, source: entry.heardAs.isEmpty ? .added : .learned)
        }
        let known = Set(learned.map(\.term))
        let vocabulary = store.settings.dictation.vocabulary.filter { !known.contains($0) }.map {
            Word(term: $0, heardAs: [], source: .settings)
        }
        // Newest first: the file keeps them oldest first.
        words = learned.reversed() + vocabulary
    }

    private func load() -> LearnedDictionary {
        LearnedDictionary(text: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
    }

    private func save(_ dictionary: LearnedDictionary) {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try dictionary.text.write(to: file, atomically: true, encoding: .utf8)
            message = nil
        } catch {
            message = "Could not save the dictionary: \(ErrorText.describe(error))"
        }
        read()
    }
}
