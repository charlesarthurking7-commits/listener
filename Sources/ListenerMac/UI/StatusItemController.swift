import AppKit
import ListenerCore

/// The menu bar icon and its menu. The icon is a template waveform like any other menu
/// bar extra, filled while listening.
/// Hotkeys show right-aligned in the titles rather than as key equivalents, so pressing
/// one while the menu is open cannot fire twice.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        var toggleWindow: () -> Void
        var isWindowVisible: () -> Bool
        var moveWindowToTopCentre: () -> Void
        var quit: () -> Void
    }

    private let statusItem: NSStatusItem
    private let model: CallModel
    private let dictation: DictationController
    private let actions: Actions

    init(model: CallModel, dictation: DictationController, actions: Actions) {
        self.model = model
        self.dictation = dictation
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        update(listening: false, hiddenFromSharing: false)
    }

    /// Monochrome like the menu bar's other icons, and filled while listening, so a call
    /// in progress shows without colour; macOS's orange dot shows the microphone is on. A
    /// small dot beside it says the window is hidden from screen sharing.
    func update(listening: Bool, hiddenFromSharing: Bool) {
        guard let button = statusItem.button,
            let glyph = NSImage(
                systemSymbolName: listening ? "waveform.circle.fill" : "waveform", accessibilityDescription: nil)
        else {
            return
        }
        let image = hiddenFromSharing ? Self.withDot(glyph) : glyph
        image.isTemplate = true
        let state = [listening ? "listening" : "not listening", hiddenFromSharing ? "hidden from screen sharing" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        image.accessibilityDescription = "Listener, \(state)"
        button.image = image
        button.toolTip = "Listener: \(state)"
    }

    /// The glyph with a small dot at its bottom right.
    private static func withDot(_ glyph: NSImage) -> NSImage {
        let dot: CGFloat = 3
        let size = NSSize(width: glyph.size.width + 2 + dot, height: glyph.size.height)
        return NSImage(size: size, flipped: false) { rect in
            glyph.draw(in: NSRect(origin: .zero, size: glyph.size))
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - dot, y: 1, width: dot, height: dot)).fill()
            return true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = model.state

        menu.addItem(NSMenuItem.sectionHeader(title: statusTitle(state)))

        let toggle: (title: String, symbol: String)
        switch state.phase {
        case .starting: toggle = ("Starting…", "record.circle")
        case .listening: toggle = ("Stop Listening", "stop.circle")
        case .stopping: toggle = ("Saving…", "record.circle")
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
            Entry("Recap So Far", AnswerTier.recap.symbol, .recap, enabled: state.canAsk) { $0.model.ask(.recap) },
        ]
        let tabStop = shortcutTabStop(for: entries)
        for entry in entries {
            menu.addItem(item(entry, tabStop: tabStop))
        }
        if dictation.isEnabled {
            menu.addItem(.separator())
            addDictationItems(to: menu, callRunning: !state.canStart)
        }
        menu.addItem(.separator())
        menu.addItem(callTypeItem(enabled: state.canStart))
        let windowEntry = Entry(
            actions.isWindowVisible() ? "Hide Window" : "Show Window", "macwindow", .toggleWindow
        ) { $0.actions.toggleWindow() }
        menu.addItem(item(windowEntry, tabStop: shortcutTabStop(for: [windowEntry])))
        menu.addItem(windowSettingsItem())
        if let summary = model.lastSummaryFile {
            menu.addItem(item(Entry("Open Last Summary", "doc.text") { $0.model.perform(.openFile(path: summary)) }))
        }
        menu.addItem(item(Entry("Open Sessions Folder", "folder") { $0.model.openSessionsFolder() }))
        menu.addItem(item(Entry("Open Settings File", "gearshape") { $0.model.openSettingsFile() }))
        menu.addItem(.separator())
        menu.addItem(item(Entry("Quit Listener", "power") { $0.actions.quit() }))
    }

    private func addDictationItems(to menu: NSMenu, callRunning: Bool) {
        guard DictationSetup.hasAccessibility else {
            let allow = Entry("Allow Dictation in Accessibility…", "mic.badge.plus") { _ in
                DictationSetup.openAccessibilitySettings()
            }
            menu.addItem(item(allow))
            return
        }
        let listening = dictation.phase == .listening
        let dictate = Entry(
            listening ? "Stop Dictating" : "Dictate", listening ? "stop.circle" : "mic", shortcut: "fn fn",
            enabled: listening || (!dictation.isActive && !callRunning)
        ) { $0.dictation.toggle() }
        menu.addItem(item(dictate, tabStop: shortcutTabStop(for: [dictate])))
        if dictation.hasLastDictation {
            menu.addItem(item(Entry("Copy Last Dictation", "doc.on.doc") { $0.dictation.copyLastText() }))
        }
        menu.addItem(item(Entry("Open Dictionary", "character.book.closed") { $0.dictation.openDictionary() }))
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

    /// Where the window sits and how it looks during a call.
    private func windowSettingsItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(item(Entry("Move to Top Centre", "arrow.up.to.line") { $0.actions.moveWindowToTopCentre() }))
        submenu.addItem(.separator())
        submenu.addItem(NSMenuItem.sectionHeader(title: "Transparency"))
        for transparency in WindowTransparency.allCases {
            let entry = ClosureMenuItem(title: transparency.title) { [weak self] in
                self?.model.setTransparency(transparency)
            }
            entry.state = model.transparency == transparency ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let transcript = ClosureMenuItem(title: "Show Transcript During Calls") { [weak self] in
            self?.model.toggleTranscriptInCall()
        }
        transcript.state = model.showsTranscriptInCall ? .on : .off
        submenu.addItem(transcript)
        let sharing = ClosureMenuItem(title: "Hide During Screen Sharing") { [weak self] in
            self?.model.toggleHidingFromScreenSharing()
        }
        sharing.state = model.hidesFromScreenSharing ? .on : .off
        sharing.toolTip = "Sharing your whole screen leaves the window out. Screenshots do too."
        submenu.addItem(sharing)

        let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        if #available(macOS 26.0, *) {
            item.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
        }
        item.submenu = submenu
        return item
    }

    /// The call types, the picked one ticked. A call keeps the type it started with.
    private func callTypeItem(enabled: Bool) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for name in model.callTypes {
            let entry = ClosureMenuItem(title: name) { [weak self] in
                self?.model.selectCallType(name)
            }
            entry.state = name == model.callType ? .on : .off
            entry.isEnabled = enabled
            submenu.addItem(entry)
        }
        let item = NSMenuItem(title: "Call Type", action: nil, keyEquivalent: "")
        if #available(macOS 26.0, *) {
            item.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: nil)
        }
        item.submenu = submenu
        return item
    }

    private struct Entry {
        let title: String
        let symbol: String
        let action: HotkeyAction?
        /// Shown when there is no hotkey action, e.g. "fn fn".
        let shortcut: String?
        let enabled: Bool
        let perform: (StatusItemController) -> Void

        init(
            _ title: String, _ symbol: String, _ action: HotkeyAction? = nil, shortcut: String? = nil,
            enabled: Bool = true, perform: @escaping (StatusItemController) -> Void
        ) {
            self.title = title
            self.symbol = symbol
            self.action = action
            self.shortcut = shortcut
            self.enabled = enabled
            self.perform = perform
        }

        @MainActor func shortcutText(_ hotkeys: [HotkeyAction: Hotkey]) -> String? {
            action.flatMap { hotkeys[$0]?.displayString } ?? shortcut
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
        if let tabStop, let shortcut = entry.shortcutText(model.activeHotkeys) {
            item.attributedTitle = Self.title(entry.title, shortcut: shortcut, tabStop: tabStop)
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
        let shortcuts = entries.compactMap { $0.shortcutText(model.activeHotkeys) }.map(width).max() ?? 0
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
