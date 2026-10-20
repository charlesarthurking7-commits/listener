import AppKit
import ListenerCore

/// The menu bar icon and its menu. Idle, the icon is a template waveform like any other
/// menu bar extra; while listening it becomes a red capsule that cannot be missed.
/// Hotkeys show right-aligned in the titles rather than as key equivalents, so pressing
/// one while the menu is open cannot fire twice.
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
        if listening {
            button.image = Self.listeningImage
            button.toolTip = "Listener is listening"
        } else {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Listener, not listening")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Listener: not listening"
        }
    }

    /// A red capsule with white bars, drawn rather than tinted so it stays red on any
    /// menu bar, light, dark or tinted by the wallpaper.
    private static let listeningImage: NSImage = {
        let image = NSImage(size: NSSize(width: 26, height: 16), flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            NSColor.white.setFill()
            let bars: [(x: CGFloat, height: CGFloat)] = [(6, 4), (10, 9), (14, 12), (18, 6)]
            for bar in bars {
                let barRect = NSRect(x: bar.x, y: (rect.height - bar.height) / 2, width: 2, height: bar.height)
                NSBezierPath(roundedRect: barRect, xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Listener is listening"
        return image
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = model.state

        menu.addItem(NSMenuItem.sectionHeader(title: statusTitle(state)))

        let toggle: (title: String, symbol: String)
        switch state.phase {
        case .starting: toggle = ("Starting…", "record.circle")
        case .listening: toggle = ("Stop Listening", "stop.circle")
        case .stopping, .summarizing: toggle = ("Saving…", "record.circle")
        case .idle, .finished: toggle = ("Start Listening", "record.circle")
        }
        let entries: [Entry] = [
            Entry(toggle.title, toggle.symbol, .toggleListening, enabled: state.canStart || state.canStop) {
                $0.model.toggleListening()
            },
            Entry("Quick Answer", AnswerTier.quick.symbol, .quickAnswer, enabled: state.canAsk) {
                $0.model.ask(.quick)
            },
            Entry("Deep Answer", AnswerTier.deep.symbol, .deepAnswer, enabled: state.canAsk) { $0.model.ask(.deep) },
        ]
        let tabStop = shortcutTabStop(for: entries)
        for entry in entries {
            menu.addItem(item(entry, tabStop: tabStop))
        }
        menu.addItem(.separator())
        menu.addItem(item(Entry("Show Window", "macwindow") { $0.actions.showWindow() }))
        if let summary = model.lastSummaryFile {
            menu.addItem(item(Entry("Open Last Summary", "doc.text") { $0.model.perform(.openFile(path: summary)) }))
        }
        menu.addItem(item(Entry("Open Sessions Folder", "folder") { $0.model.openSessionsFolder() }))
        menu.addItem(item(Entry("Open Settings File", "gearshape") { $0.model.openSettingsFile() }))
        menu.addItem(.separator())
        menu.addItem(item(Entry("Quit Listener", "power") { $0.actions.quit() }))
    }

    private func statusTitle(_ state: CallViewState) -> String {
        guard state.phase == .listening else {
            return "Not listening"
        }
        guard let since = state.listeningSince else {
            return "Listening"
        }
        return "Listening · \(DisplayFormat.clock(Date().timeIntervalSince(since)))"
    }

    private struct Entry {
        let title: String
        let symbol: String
        let action: HotkeyAction?
        let enabled: Bool
        let perform: (StatusItemController) -> Void

        init(
            _ title: String, _ symbol: String, _ action: HotkeyAction? = nil, enabled: Bool = true,
            perform: @escaping (StatusItemController) -> Void
        ) {
            self.title = title
            self.symbol = symbol
            self.action = action
            self.enabled = enabled
            self.perform = perform
        }
    }

    private func item(_ entry: Entry, tabStop: CGFloat? = nil) -> NSMenuItem {
        let item = ClosureMenuItem(
            title: entry.title,
            perform: { [weak self] in
                if let self {
                    entry.perform(self)
                }
            })
        if let tabStop, let action = entry.action, let hotkey = model.activeHotkeys[action] {
            item.attributedTitle = Self.title(entry.title, shortcut: hotkey.displayString, tabStop: tabStop)
        }
        // macOS 26 menus give most items an icon; earlier menus look busy with them.
        if #available(macOS 26.0, *) {
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
        }
        item.isEnabled = entry.enabled
        return item
    }

    /// Far enough right that every title and its shortcut fit with a clear gap.
    private func shortcutTabStop(for entries: [Entry]) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        func width(_ text: String) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        let titles = entries.map { width($0.title) }.max() ?? 0
        let shortcuts =
            entries.compactMap { $0.action.flatMap { model.activeHotkeys[$0] } }
            .map { width($0.displayString) }.max() ?? 0
        return ceil(titles + 32 + shortcuts)
    }

    /// The title, a tab, and the shortcut against a right-aligned tab stop. No colour is
    /// set, so the menu still dims disabled items and inverts the highlighted one.
    private static func title(_ title: String, shortcut: String, tabStop: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: tabStop)]
        return NSAttributedString(
            string: "\(title)\t\(shortcut)",
            attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph])
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
