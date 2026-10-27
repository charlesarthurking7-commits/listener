import AppKit

/// The menu bar while the main window is open. It matters most for Edit: without it,
/// Copy, Paste and Undo do nothing in the window's text fields.
@MainActor
enum MainMenu {
    static func make(
        openSettings: @escaping () -> Void, showSection: @escaping (MainWindowModel.Section) -> Void
    ) -> NSMenu {
        let menu = NSMenu()

        let app = submenu(in: menu, title: "Listener")
        app.addItem(
            withTitle: "About Listener", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(ClosureItem(title: "Settings…", keyEquivalent: ",", perform: openSettings))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Listener", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Listener", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(in: menu, title: "File")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu(in: menu, title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = submenu(in: menu, title: "View")
        for (index, section) in MainWindowModel.Section.allCases.enumerated() {
            view.addItem(ClosureItem(title: section.title, keyEquivalent: "\(index + 1)") { showSection(section) })
        }

        let window = submenu(in: menu, title: "Window")
        window.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        return menu
    }

    private static func submenu(in menu: NSMenu, title: String) -> NSMenu {
        let submenu = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
        return submenu
    }

    private final class ClosureItem: NSMenuItem {
        private let perform: () -> Void

        init(title: String, keyEquivalent: String, perform: @escaping () -> Void) {
            self.perform = perform
            super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
            target = self
        }

        required init(coder: NSCoder) {
            fatalError("ClosureItem is created in code only")
        }

        @objc private func run() {
            perform()
        }
    }
}
