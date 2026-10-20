import AppKit
import ListenerCore
import SwiftUI

/// The always-on-top window. A non-activating panel: clicking it never takes focus
/// away from Meet or Teams, it shows on every Space and over full-screen apps, and
/// it remembers where it was and how big it was.
final class FloatingPanel: NSPanel {
    private static let frameName = "ListenerWindow"

    init(rootView: some View, window: WindowSettings) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = window.alwaysOnTop
        level = window.alwaysOnTop ? .floating : .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
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

        let background = NSVisualEffectView()
        background.material = .hudWindow
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
            placeInTopRightCorner()
        }
        setFrameAutosaveName(Self.frameName)
    }

    /// Shows the panel without activating Listener.
    func show() {
        orderFrontRegardless()
    }

    private func placeInTopRightCorner() {
        guard let screen = NSScreen.main?.visibleFrame else {
            center()
            return
        }
        let margin: CGFloat = 20
        setFrameOrigin(NSPoint(x: screen.maxX - frame.width - margin, y: screen.maxY - frame.height - margin))
    }
}

/// Buttons in a window that is not key would otherwise swallow the first click.
private final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
