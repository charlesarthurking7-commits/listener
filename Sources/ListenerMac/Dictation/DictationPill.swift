import AppKit
import SwiftUI

/// The small capsule at the bottom of the screen while dictating: bars that follow your
/// voice, a ripple while the words are tidied, or a short note. It never takes focus, so
/// the cursor stays where the text is going, and takes clicks only to undo a word it has
/// just learned, shrunk to the capsule so nothing around it stops being clickable.
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
        let host = FirstClickHostingView(rootView: DictationPillView(controller: controller))
        host.safeAreaRegions = []
        contentView = host
        follow()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func follow() {
        withObservationTracking {
            update(visible: controller.phase != .idle)
            let offersUndo = if case .learned = controller.phase { true } else { false }
            if offersUndo == ignoresMouseEvents {
                ignoresMouseEvents = !offersUndo
                // After SwiftUI has laid the capsule out for its new content.
                DispatchQueue.main.async { [weak self] in
                    self?.placeOnScreen(fitting: offersUndo)
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.follow()
            }
        }
    }

    private func update(visible: Bool) {
        if visible, !isVisible {
            placeOnScreen(fitting: !ignoresMouseEvents)
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

    /// Bottom centre of the screen being worked on, just above the Dock. `fitting` shrinks
    /// the panel to the capsule, for while it takes clicks.
    private func placeOnScreen(fitting: Bool) {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            return
        }
        let size = fitting ? (contentView?.fittingSize ?? Self.size) : Self.size
        let bottom = visible.minY + 6
        setFrame(
            NSRect(x: visible.midX - size.width / 2, y: bottom, width: size.width, height: size.height), display: true)
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
            .padding([.horizontal, .top], PillLayout.shadowRoom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, PillLayout.bottomGap)
            .animation(.snappy(duration: 0.2), value: shown)
            .onChange(of: controller.phase, initial: true) { _, phase in
                if phase != .idle {
                    shown = phase
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch shown {
        case .idle, .listening:
            LevelBars(level: controller.level)
                .accessibilityElement()
                .accessibilityLabel("Dictating")
        case .working:
            RippleBars()
                .accessibilityElement()
                .accessibilityLabel("Typing what you said")
        case .note(let text):
            note(text)
        case .learned(let term):
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.green)
                note(
                    "Added \u{201C}\(term.count > 24 ? term.prefix(23) + "\u{2026}" : term)\u{201D} to your dictionary")
                Button("Undo") {
                    controller.undoLearned()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Color.white.opacity(0.14), in: Capsule())
                .padding(.trailing, -9)
                .accessibilityHint("Forgets the word again")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
    }
}

private enum PillLayout {
    /// Clear space around the capsule for its shadow.
    static let shadowRoom: CGFloat = 12
    static let bottomGap: CGFloat = 10
}

/// Takes the click that lands on Undo even though the panel is never key.
private final class FirstClickHostingView: NSHostingView<DictationPillView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
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
