import AppKit
import ListenerCore

/// The menu bar icon: a waveform that turns red while listening, and a menu with
/// the main actions. Hotkeys appear in the titles rather than as key equivalents,
/// so pressing one while the menu is open cannot fire twice.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        var showWindow: () -> Void
        var quit: () -> Void
    }

    private let statusItem: NSStatusItem
    private let model: CallModel
    private let actions: Actions

    init(model: CallModel, actions: Actions) {
        self.model = model
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        update(listening: false)
    }

    func update(listening: Bool) {
        guard let button = statusItem.button else {
            return
        }
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Listener")
        if listening, let red = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        {
            red.isTemplate = false
            button.image = red
            button.toolTip = "Listener: listening"
        } else {
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Listener: not listening"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = model.state

        let toggleTitle: String
        switch state.phase {
        case .starting: toggleTitle = "Starting..."
        case .listening: toggleTitle = "Stop Listening"
        case .stopping, .summarizing: toggleTitle = "Saving..."
        case .idle, .finished: toggleTitle = "Start Listening"
        }
        menu.addItem(
            item(toggleTitle, for: .toggleListening, enabled: state.canStart || state.canStop) {
                $0.model.toggleListening()
            })
        menu.addItem(item("Quick Answer", for: .quickAnswer, enabled: state.canAsk) { $0.model.ask(.quick) })
        menu.addItem(item("Deep Answer", for: .deepAnswer, enabled: state.canAsk) { $0.model.ask(.deep) })
        menu.addItem(.separator())
        menu.addItem(item("Show Window") { $0.actions.showWindow() })
        menu.addItem(item("Open Sessions Folder") { $0.model.openSessionsFolder() })
        menu.addItem(item("Open Settings File") { $0.model.openSettingsFile() })
        menu.addItem(.separator())
        menu.addItem(item("Quit Listener") { $0.actions.quit() })
    }

    private func item(
        _ title: String, for action: HotkeyAction? = nil, enabled: Bool = true,
        perform: @escaping (StatusItemController) -> Void
    ) -> NSMenuItem {
        var fullTitle = title
        if let action, let hotkey = model.activeHotkeys[action] {
            fullTitle += "  (\(hotkey.displayString))"
        }
        let item = ClosureMenuItem(
            title: fullTitle,
            perform: { [weak self] in
                if let self {
                    perform(self)
                }
            })
        item.isEnabled = enabled
        return item
    }
}

/// A menu item that runs a closure, so the menu needs no selector per action.
private final class ClosureMenuItem: NSMenuItem {
    private let perform: () -> Void

    init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem is created in code only")
    }

    @objc private func run() {
        perform()
    }
}
