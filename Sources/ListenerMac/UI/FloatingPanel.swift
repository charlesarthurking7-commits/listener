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
    private static let minimumSize = NSSize(width: 320, height: 360)
    private static let margin: CGFloat = 24

    private let background = NSVisualEffectView()
    /// The size to go back to when a call's compact bar gives way to the full window.
    private var expandedFrame: NSRect?
    /// The latest height asked for, applied once SwiftUI has finished laying out.
    private var pendingFit: CGFloat??

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
        minSize = Self.minimumSize
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }

        // One material for the whole window, behind everything; nothing inside adds its
        // own blur. The popover material follows light and dark mode and is dense
        // enough to read text over any background, and macOS makes it opaque with
        // Reduce Transparency.
        background.material = .popover
        background.blendingMode = .behindWindow
        // Listener is never the active app, and inactive windows lose their vibrancy
        // unless the effect is forced on.
        background.state = .active

        let host = FirstClickHostingView(rootView: AnyView(rootView))
        host.sizingOptions = [.minSize]
        // The header draws where the hidden title bar would be, so the content has no
        // safe area to keep clear, and its size must not count one.
        host.safeAreaRegions = []
        // Side by side rather than nested, so Clear can turn the blur off and keep the content.
        let container = NSView()
        for view in [background, host] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        contentView = container

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

    /// Sizes the window to the compact bar and its card, keeping the top edge where it
    /// is so an answer grows downwards. Nil goes back to the full window. The compact
    /// size is never saved, so the next launch opens full size.
    ///
    /// SwiftUI asks for this while it lays the window out, and resizing the window there
    /// leaves the content a different size from it, so the change waits for the next
    /// turn of the run loop.
    func fitContent(height: CGFloat?) {
        let scheduled = pendingFit != nil
        pendingFit = .some(height)
        if !scheduled {
            DispatchQueue.main.async { [weak self] in
                guard let self, let height = pendingFit else {
                    return
                }
                pendingFit = nil
                applyFit(height: height)
            }
        }
    }

    private func applyFit(height: CGFloat?) {
        if let height {
            if expandedFrame == nil {
                expandedFrame = frame
                setFrameAutosaveName("")
                minSize = NSSize(width: Self.minimumSize.width, height: 1)
            }
            setFrame(topAnchored(height: height), display: true)
        } else if let expanded = expandedFrame {
            expandedFrame = nil
            minSize = Self.minimumSize
            setFrame(constrainFrameRect(topAnchored(height: expanded.height), to: screen), display: true)
            setFrameAutosaveName(Self.frameName)
        }
    }

    /// Solid uses the material's opaque form, which is also what macOS shows with Reduce
    /// Transparency. Clear drops the blur for a dark tint (drawn by the content) with light
    /// text, which reads over anything, in Light Mode too. Hiding from screen sharing
    /// leaves the window out of every capture, screenshots included.
    func apply(transparency: WindowTransparency, opacity: Double, hiddenFromSharing: Bool) {
        background.state = transparency == .solid ? .inactive : .active
        background.isHidden = transparency == .clear
        appearance = transparency == .clear ? NSAppearance(named: .darkAqua) : nil
        if abs(alphaValue - opacity) > 0.001 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                animator().alphaValue = opacity
            }
        }
        sharingType = hiddenFromSharing ? .none : .readOnly
    }

    /// Just under the menu bar in the middle of the screen, close to the camera.
    func moveToTopCentre() {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else {
            return
        }
        let origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - frame.height - 8)
        setFrameOrigin(origin)
    }

    private func topAnchored(height: CGFloat) -> NSRect {
        NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
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
