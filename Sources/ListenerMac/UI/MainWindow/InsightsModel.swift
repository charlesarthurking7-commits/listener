import AppKit
import ListenerCore
import Observation
import UniformTypeIdentifiers

/// The Insights section: how much has been dictated, how fast, into which apps and on
/// which days, and what the last 30 days of calls came to. Dictation's counts come from
/// dictation-stats.json, which is read again whenever it changes.
@MainActor
@Observable
final class InsightsModel {
    struct App: Identifiable {
        var id: String
        var name: String
        var words: Int
        var icon: NSImage
    }

    struct CallTotals {
        var calls = 0
        var seconds = 0.0
        var answers = 0
        var openToDos = 0
    }

    /// The calls counted, which is as long as calls are usually kept.
    static let callDays = 30

    private(set) var stats = DictationStats()
    private let calls: CallsModel
    private let statsFile: URL
    @ObservationIgnored private let watcher = FolderWatcher()
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    init(calls: CallsModel, environment: AppEnvironment) {
        self.calls = calls
        statsFile = environment.paths.dictationStatsFile
    }

    func refresh() {
        watcher.watch(statsFile.deletingLastPathComponent()) { [weak self] in
            self?.read()
        }
        read()
    }

    func stopWatching() {
        watcher.stop()
    }

    /// The apps dictated into most, by words, then how many others there were and their
    /// words. Dictations from before apps were counted are left out.
    func topApps(_ limit: Int) -> (apps: [App], others: Int, otherWords: Int) {
        let ranked = stats.total.apps.sorted { $0.value > $1.value || $0.value == $1.value && $0.key < $1.key }
        let apps = ranked.prefix(limit).map { key, words in
            App(id: key, name: stats.appNames[key] ?? key, words: words, icon: icon(for: key))
        }
        let rest = ranked.dropFirst(limit)
        return (apps, rest.count, rest.reduce(0) { $0 + $1.value })
    }

    var recentCalls: CallTotals {
        let since = Calendar.current.date(byAdding: .day, value: -Self.callDays, to: Date()) ?? .distantPast
        return calls.listedCalls.filter { $0.startedAt >= since }.reduce(into: CallTotals()) { totals, call in
            totals.calls += 1
            totals.seconds += call.duration ?? 0
            totals.answers += call.answerCount
            totals.openToDos += call.myOpenActionItems
        }
    }

    private func read() {
        // A file that can't be read keeps what was shown, rather than showing nothing.
        if let stats = DictationStats.load(from: statsFile) {
            self.stats = stats
        }
    }

    private func icon(for key: String) -> NSImage {
        if let icon = icons[key] {
            return icon
        }
        let icon =
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: key).map {
                NSWorkspace.shared.icon(forFile: $0.path)
            } ?? NSWorkspace.shared.icon(for: .applicationBundle)
        icons[key] = icon
        return icon
    }
}
