import AppKit
import ListenerCore
import SwiftUI

/// The always-on-top window. A non-activating panel that never becomes key: clicking
/// it never takes focus away from Meet or Teams, so typing still goes to the call.
/// It shows on every Space and over full-screen apps, and it remembers where it was
/// and how big it was.
///
/// It is borderless and draws its own corners and edge: macOS draws a window's edge as
/// part of its shadow, and over a light page that reads as a heavy outline.
final class FloatingPanel: NSPanel {
    private static let frameName = "ListenerWindow"
    /// Narrow enough to sit beside a call, tall enough for an answer and the last
    /// minute of conversation.
    private static let defaultSize = NSSize(width: 400, height: 720)
    private static let minimumSize = NSSize(width: 320, height: 360)
    private static let margin: CGFloat = 24

    private let glass = FloatingPanel.makeGlass()
    /// The size to go back to when a call's compact bar gives way to the full window.
    private var expandedFrame: NSRect?
    /// The latest height asked for, applied once SwiftUI has finished laying out.
    private var pendingFit: CGFloat??

    init(rootView: some View, window: WindowSettings) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = window.alwaysOnTop
        level = window.alwaysOnTop ? .floating : .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        alphaValue = window.opacity
        minSize = Self.minimumSize
        hasShadow = false

        let host = FirstClickHostingView(rootView: AnyView(rootView))
        host.sizingOptions = [.minSize]
        host.safeAreaRegions = []
        // Side by side rather than nested, so Solid and Clear can drop the glass and keep
        // the content, which draws their backgrounds and the edge itself.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = Theme.windowRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        for view in [glass, host] {
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

    /// Glass is drawn here; Solid's fill and Clear's dark tint are drawn by the content.
    /// Clear has light text, which reads over anything, so it is dark in Light Mode too.
    /// Hiding from screen sharing leaves the window out of every capture, screenshots
    /// included.
    func apply(transparency: WindowTransparency, opacity: Double, hiddenFromSharing: Bool) {
        glass.isHidden = transparency != .glass
        appearance = transparency == .clear ? NSAppearance(named: .darkAqua) : nil
        if abs(alphaValue - opacity) > 0.001 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                animator().alphaValue = opacity
            }
        }
        sharingType = hiddenFromSharing ? .none : .readOnly
    }

    /// Liquid Glass where macOS has it. Before macOS 26, the popover material, which
    /// follows light and dark mode and turns opaque with Reduce Transparency.
    private static func makeGlass() -> NSView {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.cornerRadius = Theme.windowRadius
                return glass
            }
        #endif
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        // Listener is never the active app, and inactive windows lose their vibrancy
        // unless the effect is forced on.
        effect.state = .active
        // A blur of what is behind the window ignores the layer's rounded corners.
        effect.maskImage = cornerMask(radius: Theme.windowRadius)
        return effect
    }

    private static func cornerMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
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
