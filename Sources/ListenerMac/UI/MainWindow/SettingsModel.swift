import AppKit
import ListenerCore
import Observation

/// The Settings section: settings.json as switches and menus, the floating window's own
/// looks, which live in the app's preferences, and the Anthropic key in the Keychain.
@MainActor
@Observable
final class SettingsModel {
    enum Page: String, CaseIterable, Identifiable {
        case general
        case answers
        case speech
        case shortcuts
        case storage
        case apiKey

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .answers: "Answers"
            case .speech: "Speech"
            case .shortcuts: "Shortcuts"
            case .storage: "Storage and privacy"
            case .apiKey: "API key"
            }
        }

        var symbol: String {
            switch self {
            case .general: "macwindow"
            case .answers: "sparkles"
            case .speech: "waveform"
            case .shortcuts: "command"
            case .storage: "lock"
            case .apiKey: "key"
            }
        }
    }

    var page = Page.general
    /// The action whose shortcut is being recorded.
    var recording: HotkeyAction?
    /// Where the Anthropic key was found, read when the page opens.
    private(set) var keySource: String?
    var keyMessage: String?

    let store: SettingsStore
    let call: CallModel
    private let environment: AppEnvironment
    /// Suspends the global hotkeys while one is recorded, so pressing it records it
    /// instead of running it.
    @ObservationIgnored var pauseHotkeys: ((Bool) -> Void)?
    @ObservationIgnored private var contextSave: Task<Void, Never>?
    @ObservationIgnored private var pendingContext: String?

    init(call: CallModel, store: SettingsStore, environment: AppEnvironment) {
        self.call = call
        self.store = store
        self.environment = environment
    }

    var settings: Settings { store.settings }

    func refresh() {
        keySource = environment.anthropicKeySource()
    }

    // MARK: About you

    /// What the box shows: the text being typed, or what is saved.
    var context: String { pendingContext ?? settings.answers.context }

    /// Saves "about you" once typing pauses, so the file isn't rewritten per letter.
    func setContext(_ text: String) {
        pendingContext = text
        contextSave?.cancel()
        contextSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else {
                return
            }
            self?.saveContext()
        }
    }

    func saveContext() {
        contextSave?.cancel()
        guard let text = pendingContext else {
            return
        }
        pendingContext = nil
        if text != settings.answers.context {
            store.set(text, at: "answers.context")
        }
    }

    // MARK: Models

    /// The models with prices in the table, so the cost shown stays right.
    var models: [String] {
        settings.prices.models.keys.sorted { Self.modelRank($0) < Self.modelRank($1) }
    }

    func setModel(_ model: ModelSettings, at path: String) {
        guard let value = try? JSONValue(encoding: model) else {
            return
        }
        store.set(value, at: path)
    }

    private static func modelRank(_ id: String) -> (Int, String) {
        let rank = ["haiku", "sonnet", "opus"].firstIndex { id.contains($0) } ?? 3
        return (rank, id)
    }

    // MARK: Shortcuts

    func startRecording(_ action: HotkeyAction) {
        recording = action
        pauseHotkeys?(true)
    }

    func stopRecording() {
        recording = nil
        pauseHotkeys?(false)
    }

    /// Takes a key pressed while recording. Escape cancels; a key that can't be a hotkey
    /// says why and keeps recording.
    func record(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard let action = recording else {
            return
        }
        if keyCode == 0x35, modifiers.intersection([.control, .option, .command]).isEmpty {
            stopRecording()
            return
        }
        guard let key = HotkeyKey.key(forKeyCode: keyCode) else {
            store.message = "That key can't be a shortcut. Use a letter, a number, Space, Return or F1 to F12."
            return
        }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key.name)
        let text = parts.joined(separator: "+")
        do {
            _ = try Hotkey(parsing: text)
        } catch {
            store.message = "\(parts.map { $0.capitalized }.joined(separator: " ")) \(error)."
            return
        }
        stopRecording()
        store.set(text, at: action.settingKey)
    }

    func resetShortcut(_ action: HotkeyAction) {
        store.set(nil, at: action.settingKey)
    }

    // MARK: Storage

    var sessionsFolder: String {
        environment.paths.abbreviating(SessionStore.root(for: settings.storage, paths: environment.paths).path)
    }

    func chooseSessionsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "New calls are saved here. Calls already saved stay where they are."
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        store.set(environment.paths.abbreviating(url.path), at: "storage.directory")
    }

    func resetSessionsFolder() {
        store.set(nil, at: "storage.directory")
    }

    func chooseCredentialsFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "Use This File"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        store.set(environment.paths.abbreviating(url.path), at: "speech.googleCredentialsFile")
    }

    func openSettingsFile() {
        if !FileManager.default.fileExists(atPath: store.file.path) {
            try? FileManager.default.createDirectory(
                at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? SettingsLoader.starterFile().write(to: store.file, options: .withoutOverwriting)
        }
        call.perform(.openFile(path: store.file.path))
    }

    // MARK: API key

    func saveKey(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-ant-") else {
            keyMessage = "That doesn't look like an Anthropic key. They start with sk-ant-."
            return
        }
        do {
            try environment.storeAnthropicKey(key)
            keyMessage = "Saved in the Keychain."
        } catch {
            keyMessage = ErrorText.describe(error)
        }
        refresh()
        call.refreshReadiness()
    }

    func removeKey() {
        let alert = NSAlert()
        alert.messageText = "Remove the Anthropic key from the Keychain?"
        alert.informativeText = "Answers, summaries and tidied dictation stop until a key is added again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        do {
            try environment.storeAnthropicKey(nil)
            keyMessage = "Removed from the Keychain."
        } catch {
            keyMessage = ErrorText.describe(error)
        }
        refresh()
        call.refreshReadiness()
    }

    func openConsole() {
        if let url = URL(string: "https://console.anthropic.com/settings/keys") {
            NSWorkspace.shared.open(url)
        }
    }
}
