import AppKit
import ListenerCore
import Observation

/// The Calls section: every saved call, a search across what was said, and the call on
/// screen. Files are read off the main thread, and the sessions folder is watched so a
/// call that has just ended, or its summary, shows up on its own.
@MainActor
@Observable
final class CallsModel {
    enum Tab: Hashable {
        case summary
        case transcript
        case answers
    }

    /// Calls under one heading in the list, such as "Today".
    struct Group: Identifiable {
        var title: String
        var rows: [Row]
        var id: String { title }
    }

    struct Row: Identifiable {
        var call: SavedCall
        var snippet: CallSearchIndex.Snippet?
        /// The call being listened to now.
        var isLive = false
        var id: URL { call.id }
    }

    private(set) var calls: [SavedCall] = []
    private(set) var detail: CallDetail?
    private(set) var isSearching = false
    private(set) var isWritingSummary = false
    /// The latest problem, shown until the next action.
    var message: String?
    var tab = Tab.summary
    /// Only calls of this type, or every call when nil.
    var typeFilter: String? {
        didSet { regroup() }
    }
    var query = "" {
        didSet { search() }
    }
    var selection: URL? {
        didSet {
            if selection != nil {
                showsSetup = false
            }
            if selection != oldValue {
                loadDetail()
            }
        }
    }
    /// The setup checklist is on screen in place of a call, until a call is picked.
    private(set) var showsSetup = false
    private(set) var groups: [Group] = []

    let call: CallModel
    private let environment: AppEnvironment
    @ObservationIgnored private var index: CallSearchIndex?
    @ObservationIgnored private var hits: [CallSearchIndex.Hit]?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private let rootWatcher = FolderWatcher()
    @ObservationIgnored private let callWatcher = FolderWatcher()
    @ObservationIgnored private var pendingReload: Task<Void, Never>?
    /// Brings the floating window forward, for the live call's page.
    @ObservationIgnored var showFloatingWindow: (() -> Void)?
    @ObservationIgnored private var showsNewest = false
    /// A call to open once the list has been read, by its folder's path.
    @ObservationIgnored private var pendingSelection: String?

    init(call: CallModel, environment: AppEnvironment) {
        self.call = call
        self.environment = environment
        followCalls()
    }

    var root: URL { SessionStore.root(for: call.settings.storage, paths: environment.paths) }

    /// The call being listened to now: the newest, while a call runs and it hasn't ended.
    var liveCallID: URL? {
        guard call.isCallRunning, let newest = calls.first, newest.duration == nil else {
            return nil
        }
        return newest.id
    }

    /// The calls the list shows: not the ones where nothing was said, such as a Start
    /// pressed by mistake. They stay on disk until the retention period deletes them.
    var listedCalls: [SavedCall] {
        let live = liveCallID
        return calls.filter { $0.turnCount > 0 || $0.answerCount > 0 || $0.hasSummary || $0.id == live }
    }

    var monthCost: Double { CallLibrary.costThisMonth(of: calls) }

    var monthCalls: Int {
        listedCalls.filter { Calendar.current.isDate($0.startedAt, equalTo: Date(), toGranularity: .month) }.count
    }

    /// The call types the saved calls used, most used first, for the filters.
    var callTypes: [String] {
        let counts = Dictionary(grouping: calls.compactMap(\.callType), by: { $0 }).mapValues(\.count)
        return counts.keys.sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 }
    }

    /// Whether Claude can write a missing summary from here. Checked when the window
    /// opens, not on every redraw, as it reads the Keychain.
    private(set) var canWriteSummary = false

    func refresh() {
        canWriteSummary = environment.makeLanguageModel() != nil
        rootWatcher.watch(root) { [weak self] in
            self?.reloadList()
        }
        reloadList()
    }

    func stopWatching() {
        rootWatcher.stop()
        callWatcher.stop()
    }

    /// Opens a call on its summary, such as the one just saved.
    func show(_ directory: URL) {
        query = ""
        typeFilter = nil
        tab = .summary
        pendingSelection = directory.resolvingSymlinksInPath().path
        reloadList()
    }

    /// Puts the setup checklist where a call's page goes.
    func showSetup() {
        selection = nil
        showsSetup = true
    }

    // MARK: Actions

    func setDone(_ done: Bool, for item: CallSummary.ActionItem) {
        guard let detail else {
            return
        }
        do {
            let summary = try CallLibrary.setDone(done, for: item, in: detail.call.directory)
            self.detail?.summary = summary
            if let index = calls.firstIndex(where: { $0.id == detail.call.id }) {
                calls[index].myOpenActionItems = summary.myOpenActionItems
                regroup()
            }
        } catch {
            message = "Could not save the tick: \(ErrorText.describe(error))"
            loadDetail()
        }
    }

    func copyEmail() {
        guard let email = detail?.summary?.email else {
            return
        }
        copy(email.text)
    }

    func copyTranscript() {
        guard let detail else {
            return
        }
        copy(
            detail.turns.map { "\($0.speaker.spokenName) \(DisplayFormat.clock($0.start)): \($0.text)" }
                .joined(separator: "\n"))
    }

    func copyAnswer(_ answer: AnswerRecord) {
        copy(AnswerMarkup(answer.text).textToSay)
    }

    func revealInFinder() {
        guard let detail else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([detail.call.directory])
    }

    func openSessionsFolder() {
        call.openSessionsFolder()
    }

    func openSummaryFile() {
        guard let detail, detail.summaryMarkdown != nil else {
            return
        }
        call.perform(.openFile(path: detail.call.directory.appendingPathComponent(SessionStore.summaryFile).path))
    }

    /// Moves the call to the Bin, after asking, so it can still be put back from Finder.
    func delete() {
        guard let detail else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Move this call to the Bin?"
        alert.informativeText = "Its transcript, answers and summary go with it. You can put it back from the Bin."
        alert.addButton(withTitle: "Move to Bin")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        do {
            try FileManager.default.trashItem(at: detail.call.directory, resultingItemURL: nil)
        } catch {
            message = "Could not move the call to the Bin: \(ErrorText.describe(error))"
            return
        }
        selection = nil
        reloadList()
    }

    /// Asks Claude for the summary of a call that has none, such as one whose summary
    /// was off or failed.
    func writeSummary() {
        guard let detail, !isWritingSummary, let model = environment.makeLanguageModel() else {
            return
        }
        isWritingSummary = true
        message = nil
        let directory = detail.call.directory
        let settings = call.settings
        Task {
            do {
                try await SessionSummarizer.summarize(directory: directory, settings: settings, model: model)
            } catch {
                message = "Could not write the summary: \(ErrorText.describe(error))"
            }
            isWritingSummary = false
            if selection == directory {
                loadDetail()
            }
            reloadList()
        }
    }

    // MARK: Reading

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Reads the list again when a call ends or its summary is written. Those land in a
    /// call's own folder, which the root's watcher does not see.
    private func followCalls() {
        withObservationTracking {
            _ = call.outcome
            _ = call.phase
            _ = call.dueSummariesFinished
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else {
                    return
                }
                // The call that has just started, or just been saved, is the one to look at.
                if self.call.outcome != nil || self.call.phase == .listening {
                    self.showsNewest = true
                }
                self.reloadList()
                self.followCalls()
            }
        }
    }

    private func reloadList() {
        let root = root
        listTask?.cancel()
        listTask = Task {
            let calls = await Task.detached { CallLibrary.calls(in: root) }.value
            guard !Task.isCancelled else {
                return
            }
            let changed = calls != self.calls
            self.calls = calls
            if changed {
                index = nil
                if !query.isEmpty {
                    search()
                }
            }
            if let selection, !calls.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
            if let pending = pendingSelection {
                pendingSelection = nil
                if let call = calls.first(where: { $0.directory.resolvingSymlinksInPath().path == pending }) {
                    selection = call.id
                }
            }
            if (selection == nil && !showsSetup) || (showsNewest && changed) {
                showsNewest = false
                selection = listedCalls.first?.id
            } else if changed {
                loadDetail()
            }
            regroup()
        }
    }

    private func loadDetail() {
        guard let directory = selection else {
            detail = nil
            callWatcher.stop()
            return
        }
        // The call being listened to is shown live from the call itself. Its files change
        // with every word, and reading them each time would be wasted work.
        guard directory != liveCallID else {
            callWatcher.stop()
            detail = nil
            return
        }
        callWatcher.watch(directory) { [weak self] in
            self?.scheduleReload()
        }
        Task {
            let loaded = await Task.detached { try? CallLibrary.detail(in: directory) }.value
            if selection == directory {
                detail = loaded
            }
        }
    }

    /// Reads the call again once its folder has been quiet for a moment, as a summary is
    /// written in a few steps.
    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled {
                self?.loadDetail()
            }
        }
    }

    /// Searches every call, building the index of their transcripts the first time.
    private func search() {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            hits = nil
            isSearching = false
            regroup()
            return
        }
        isSearching = true
        let calls = calls
        let existing = index
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else {
                return
            }
            let (index, hits) = await Task.detached {
                let index = existing ?? CallSearchIndex(calls: calls)
                return (index, index.search(query))
            }.value
            guard !Task.isCancelled else {
                return
            }
            self.index = index
            self.hits = hits
            isSearching = false
            regroup()
            if let first = hits.first, !hits.contains(where: { $0.id == selection }) {
                selection = first.id
            }
        }
    }

    private func regroup() {
        let live = liveCallID
        let listed = Set(listedCalls.map(\.id))
        let rows: [Row] =
            if let hits {
                hits.map { Row(call: $0.call, snippet: $0.snippet, isLive: $0.id == live) }
            } else {
                calls.map { Row(call: $0, snippet: nil, isLive: $0.id == live) }
            }
        let filtered = rows.filter { listed.contains($0.id) && (typeFilter == nil || $0.call.callType == typeFilter) }
        var groups: [Group] = []
        for row in filtered {
            let title = Self.groupTitle(for: row.call.startedAt)
            if groups.last?.title == title {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append(Group(title: title, rows: [row]))
            }
        }
        self.groups = groups
    }

    /// "Today", "Yesterday", a weekday this week, then "Last week" and month names.
    static func groupTitle(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return "Earlier this week"
        }
        if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
            calendar.isDate(date, equalTo: lastWeek, toGranularity: .weekOfYear)
        {
            return "Last week"
        }
        let format =
            calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMMM" : "MMMM yyyy"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.setLocalizedDateFormatFromTemplate(format)
        return formatter.string(from: date)
    }
}
