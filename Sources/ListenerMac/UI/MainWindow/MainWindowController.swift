import AppKit
import SwiftUI

/// Listener's main window: past calls, call types, the dictionary and settings. Unlike
/// the floating window it is an ordinary window that takes the keyboard, so while it is
/// open Listener is an ordinary app too, in the Dock and the app switcher.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private static let frameName = "MainWindow"
    private static let defaultSize = NSSize(width: 1200, height: 760)

    let model: MainWindowModel
    private let window: NSWindow

    init(model: MainWindowModel) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()
        window.title = "Listener"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the title bar as tall as the window's own bars,
        // with the window buttons centred in it.
        window.toolbar = NSToolbar(identifier: "MainWindow")
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 620)
        window.backgroundColor = NSColor(Theme.windowBackground)
        let host = NSHostingView(rootView: MainWindowView(model: model))
        host.safeAreaRegions = []
        window.contentView = host
        window.delegate = self
        if !window.setFrameUsingName(Self.frameName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
    }

    var isVisible: Bool { window.isVisible }

    func show(_ section: MainWindowModel.Section? = nil) {
        if let section {
            model.section = section
        }
        model.windowWillShow()
        let opening = !window.isVisible
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // SwiftUI puts the cursor in the first text field it finds, which would make a
        // search field look in use. Nothing is focused until something is clicked.
        if opening {
            DispatchQueue.main.async { [window] in
                window.makeFirstResponder(nil)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.windowDidClose()
        // settings.json's window.showDockIcon keeps the Dock icon after the window closes.
        if !model.store.settings.window.showDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
