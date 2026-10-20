import AppKit
import ListenerCore
import SwiftUI

/// The always-on-top window. A non-activating panel that never becomes key: clicking
/// it never takes focus away from Meet or Teams, so typing still goes to the call.
/// It shows on every Space and over full-screen apps, and it remembers where it was
/// and how big it was.
final class FloatingPanel: NSPanel {
    private static let frameName = "ListenerWindow"
    /// Narrow enough to sit beside a call, tall enough for an answer and the last
    /// minute of conversation.
    private static let defaultSize = NSSize(width: 400, height: 720)
    private static let margin: CGFloat = 24

    init(rootView: some View, window: WindowSettings) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = window.alwaysOnTop
        level = window.alwaysOnTop ? .floating : .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        alphaValue = window.opacity
        minSize = NSSize(width: 320, height: 360)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }

        // One material for the whole window, behind everything; nothing inside adds its
        // own blur. The popover material follows light and dark mode and is dense
        // enough to read text over any background, and macOS makes it opaque with
        // Reduce Transparency.
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        // Listener is never the active app, and inactive windows lose their vibrancy
        // unless the effect is forced on.
        background.state = .active

        let host = FirstClickHostingView(rootView: AnyView(rootView))
        host.sizingOptions = [.minSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background

        if !setFrameUsingName(Self.frameName) {
            placeForFirstLaunch()
        }
        setFrameAutosaveName(Self.frameName)
    }

    // Nothing in the window takes typing, and a key panel would take the keyboard from
    // the call app even though Listener stays inactive.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the panel without activating Listener.
    func show() {
        orderFrontRegardless()
    }

    /// The window is meant to sit beside the call on a second display, so it starts on
    /// the right edge of one if there is one, otherwise in the top right corner. After
    /// that it reopens wherever it was left.
    private func placeForFirstLaunch() {
        let screens = NSScreen.screens
        guard let screen = (screens.count > 1 ? screens.last : screens.first)?.visibleFrame else {
            center()
            return
        }
        let height = min(Self.defaultSize.height, screen.height - 2 * Self.margin)
        let size = NSSize(width: Self.defaultSize.width, height: max(height, minSize.height))
        let origin = NSPoint(x: screen.maxX - size.width - Self.margin, y: screen.maxY - size.height - Self.margin)
        setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

/// Buttons in a window that is not key would otherwise swallow the first click.
private final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// A background that moves the window when dragged. SwiftUI content does not reliably
/// count as window background for `isMovableByWindowBackground`, and the title bar it
/// would otherwise be dragged by is hidden under the header.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
