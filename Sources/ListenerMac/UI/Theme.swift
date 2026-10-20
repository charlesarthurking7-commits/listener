import ListenerCore
import SwiftUI

enum Theme {
    static let padding: CGFloat = 14
    static let cornerRadius: CGFloat = 12
    static let chipWidth: CGFloat = 46
    /// Big enough to read at a glance on a second monitor.
    static let transcriptFont = Font.system(size: 14)
    static let answerFont = Font.system(size: 15)
}

extension Speaker {
    var tint: Color {
        switch self {
        case .me: .blue
        case .them: .orange
        }
    }
}

extension AnswerTier {
    var title: String {
        switch self {
        case .quick: "Quick"
        case .deep: "Deep"
        }
    }

    var symbol: String {
        switch self {
        case .quick: "bolt.fill"
        case .deep: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .quick: .blue
        case .deep: .purple
        }
    }
}

struct SpeakerChip: View {
    let speaker: Speaker

    var body: some View {
        Text(speaker.rawValue)
            .font(.caption.weight(.semibold))
            .foregroundStyle(speaker.tint)
            .frame(width: Theme.chipWidth)
            .padding(.vertical, 2)
            .background(speaker.tint.opacity(0.16), in: Capsule())
    }
}

struct TierBadge: View {
    let tier: AnswerTier

    var body: some View {
        Label(tier.title, systemImage: tier.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tier.tint, in: Capsule())
    }
}

/// A red dot with a ring that keeps expanding from it, so listening is obvious
/// from across the desk.
struct PulsingDot: View {
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.4))
                .scaleEffect(expanded ? 1 : 0.45)
                .opacity(expanded ? 0 : 1)
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
        }
        .frame(width: 20, height: 20)
        .onAppear {
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
                expanded = true
            }
        }
        .accessibilityHidden(true)
    }
}

/// A filled button that keeps its colour. The window is never key, and macOS draws
/// `.borderedProminent` buttons grey in a window that is not key.
struct FilledButtonStyle: ButtonStyle {
    let tint: Color
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        FilledButton(configuration: configuration, tint: tint, compact: compact)
    }
}

private struct FilledButton: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(compact ? .callout.weight(.medium) : .body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 4 : 6)
            .background(tint.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}
