import ListenerCore
import Observation

/// What the main window shows: which section, and each section's own model.
@MainActor
@Observable
final class MainWindowModel {
    enum Section: String, CaseIterable, Identifiable {
        case calls
        case callTypes
        case dictionary
        case settings

        var id: Self { self }

        /// From `--open`: "calls", "call-types", "dictionary" or "settings".
        init?(argument: String) {
            switch argument.lowercased() {
            case "calls": self = .calls
            case "call-types", "calltypes": self = .callTypes
            case "dictionary": self = .dictionary
            case "settings": self = .settings
            default: return nil
            }
        }

        var title: String {
            switch self {
            case .calls: "Calls"
            case .callTypes: "Call types"
            case .dictionary: "Dictionary"
            case .settings: "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .calls: "waveform"
            case .callTypes: "square.grid.2x2"
            case .dictionary: "character.book.closed"
            case .settings: "slider.horizontal.3"
            }
        }
    }

    var section = Section.calls
    let call: CallModel
    let calls: CallsModel
    let callTypes: CallTypesModel
    let dictionary: DictionaryModel
    let settings: SettingsModel
    let store: SettingsStore

    init(call: CallModel, dictation: DictationController, environment: AppEnvironment) {
        self.call = call
        store = SettingsStore(environment: environment)
        calls = CallsModel(call: call, environment: environment)
        callTypes = CallTypesModel(call: call, environment: environment)
        dictionary = DictionaryModel(dictation: dictation, store: store, environment: environment)
        settings = SettingsModel(call: call, store: store, environment: environment)
    }

    /// Start and Stop in the sidebar. A call started here brings up the floating window,
    /// as the hotkey does: it stays on top of the call app, where answers are wanted.
    func toggleCall() {
        let starting = !call.isInCall
        call.toggleListening()
        if starting {
            calls.showFloatingWindow?()
        }
    }

    /// The number beside a section in the sidebar, if it has one.
    func count(for section: Section) -> Int? {
        switch section {
        case .calls: calls.listedCalls.count
        case .callTypes: callTypes.names.count
        case .dictionary: dictionary.words.count
        case .settings: nil
        }
    }

    /// Everything is read again when the window opens: calls may have ended and files
    /// changed while it was closed.
    func windowWillShow() {
        store.reload()
        calls.refresh()
        callTypes.refresh()
        dictionary.refresh()
        settings.refresh()
    }

    func windowDidClose() {
        calls.stopWatching()
        callTypes.stopWatching()
        dictionary.stopWatching()
    }
}
