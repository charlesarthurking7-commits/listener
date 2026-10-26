import AppKit
import SwiftUI

/// The small capsule at the bottom of the screen while dictating: bars that follow your
/// voice, a ripple while the words are tidied, or a short note. It never takes focus or
/// clicks, so the cursor stays where the text is going.
@MainActor
final class DictationPill: NSPanel {
    private static let size = NSSize(width: 440, height: 64)
    private static let fade: TimeInterval = 0.15

    private let controller: DictationController

    init(controller: DictationController) {
        self.controller = controller
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        let host = NSHostingView(rootView: DictationPillView(controller: controller))
        host.safeAreaRegions = []
        contentView = host
        follow()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func follow() {
        withObservationTracking {
            update(visible: controller.phase != .idle)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.follow()
            }
        }
    }

    private func update(visible: Bool) {
        if visible, !isVisible {
            placeOnScreen()
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fade
                animator().alphaValue = 1
            }
        } else if !visible, isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fade
                animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    if self.controller.phase == .idle {
                        self.orderOut(nil)
                    }
                }
            }
        }
    }

    /// Bottom centre of the screen being worked on, just above the Dock.
    private func placeOnScreen() {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            return
        }
        setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 6))
    }
}

private struct DictationPillView: View {
    let controller: DictationController
    /// What the capsule showed last, kept while it fades out so it does not collapse.
    @State private var shown = DictationController.Phase.idle

    var body: some View {
        content
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(Color.black.opacity(0.84)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 10)
            .animation(.snappy(duration: 0.2), value: shown)
            .onChange(of: controller.phase, initial: true) { _, phase in
                if phase != .idle {
                    shown = phase
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var content: some View {
        switch shown {
        case .idle, .listening:
            LevelBars(level: controller.level)
        case .working:
            RippleBars()
        case .note(let text):
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var accessibilityLabel: String {
        switch shown {
        case .idle, .listening: "Dictating"
        case .working: "Typing what you said"
        case .note(let text): text
        }
    }
}

/// Bars whose height follows the microphone level, tallest in the middle.
private struct LevelBars: View {
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: PillBars.gap) {
            ForEach(PillBars.weights.indices, id: \.self) { index in
                // A little unevenness each update makes it read as a voice, not a meter.
                let wobble = reduceMotion ? 1 : Double.random(in: 0.75...1)
                PillBars.bar(height: PillBars.height(for: level * PillBars.weights[index] * wobble))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
    }
}

/// The same bars rippling while the speech is settled and tidied.
private struct RippleBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: PillBars.gap) {
                ForEach(PillBars.weights.indices, id: \.self) { index in
                    let wave = (sin(time * 7 - Double(index) * 0.8) + 1) / 2
                    PillBars.bar(height: PillBars.height(for: reduceMotion ? 0.3 : 0.15 + wave * 0.35))
                }
            }
        }
    }
}

private enum PillBars {
    static let weights = [0.45, 0.7, 0.9, 1, 0.9, 0.7, 0.45]
    static let gap: CGFloat = 3
    static let width: CGFloat = 3
    static let minHeight: CGFloat = 3
    static let maxHeight: CGFloat = 16

    static func height(for fraction: Double) -> CGFloat {
        minHeight + (maxHeight - minHeight) * CGFloat(min(max(fraction, 0), 1))
    }

    static func bar(height: CGFloat) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.92))
            .frame(width: width, height: height)
            .frame(height: maxHeight)
    }
}
