import AppKit
import ListenerCore
import SwiftUI

/// The window's design tokens: a 4 pt grid, one accent, calm speaker colours and type
/// sizes that read from a metre away on a second monitor.
enum Theme {
    static let gutter: CGFloat = 16
    static let headerHeight: CGFloat = 52
    static let footerHeight: CGFloat = 36
    static let cardRadius: CGFloat = 12
    static let windowRadius: CGFloat = 20
    static let bannerRadius: CGFloat = 10
    static let cardInset: CGFloat = 12

    static let transcriptFont = Font.system(size: 14)
    static let transcriptLineSpacing: CGFloat = 3
    static let answerSize: CGFloat = 17
    static let answerFont = Font.system(size: answerSize)
    static let answerLineSpacing: CGFloat = 4
    static let metaFont = Font.system(size: 11, weight: .medium)

    static let cardFill = Color.adaptive(light: NSColor(white: 1, alpha: 0.72), dark: NSColor(white: 1, alpha: 0.055))
    static let cardStroke = Color.adaptive(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.09))
    static let fill = Color.adaptive(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.07))
    static let strongFill = Color.adaptive(light: NSColor(white: 0, alpha: 0.075), dark: NSColor(white: 1, alpha: 0.11))
    static let keycapFill = Color.adaptive(light: NSColor(white: 1, alpha: 0.9), dark: NSColor(white: 1, alpha: 0.08))
    /// Clear's whole background: dark enough under light text to read over video or a
    /// busy desktop, light enough to see through.
    static let clearTint = Color.black.opacity(0.42)
    /// The window's own edge: enough to separate it from a page of the same colour, never
    /// a dark outline.
    static let windowEdge = Color.adaptive(
        light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.16))
    static let keycapEdge = Color.adaptive(light: NSColor(white: 0, alpha: 0.13), dark: NSColor(white: 1, alpha: 0.14))

    /// Notes meant only for the user: a sticky-note yellow in light mode, a neutral
    /// panel with a yellow label in dark mode, where a yellow tint turns muddy.
    static let noteLabel = Color.adaptive(
        light: NSColor(srgbRed: 0.63, green: 0.35, blue: 0, alpha: 1), dark: .systemYellow)
    static let noteFill = Color.adaptive(
        light: NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 0.16), dark: NSColor(white: 1, alpha: 0.065))
}

extension Color {
    /// A colour that follows the window's light or dark appearance.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
    }
}

extension Speaker {
    /// Cool for the user, warm for the other side. Deep enough in light mode to pass
    /// contrast as small text, bright enough in dark mode to find at a glance.
    var tint: Color {
        switch self {
        case .me:
            Color.adaptive(
                light: NSColor(srgbRed: 0.04, green: 0.5, blue: 0.66, alpha: 1),
                dark: NSColor(srgbRed: 0.39, green: 0.82, blue: 1, alpha: 1))
        case .them:
            Color.adaptive(
                light: NSColor(srgbRed: 0.77, green: 0.35, blue: 0, alpha: 1),
                dark: NSColor(srgbRed: 1, green: 0.7, blue: 0.25, alpha: 1))
        }
    }

    var spokenName: String {
        switch self {
        case .me: "You"
        case .them: "Them"
        }
    }
}

extension AnswerTier {
    var title: String {
        switch self {
        case .quick: "Quick"
        case .deep: "Deep"
        case .recap: "Recap"
        }
    }

    /// What the card holds, for help text and VoiceOver, e.g. "quick answer".
    var noun: String {
        switch self {
        case .quick: "quick answer"
        case .deep: "deep answer"
        case .recap: "recap"
        }
    }

    var symbol: String {
        switch self {
        case .quick: "bolt.fill"
        case .deep: "sparkles"
        case .recap: "list.bullet"
        }
    }

    var tint: Color {
        switch self {
        case .quick: .accentColor
        case .deep: .purple
        case .recap: .teal
        }
    }
}

/// A one-pixel separator at any display scale.
struct Hairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1 / displayScale)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A rounded panel behind the view, `fill` inside a hairline `stroke`.
    func panel(
        _ fill: Color = Theme.cardFill, radius: CGFloat = Theme.cardRadius, stroke: Color = Theme.cardStroke,
        lineWidth: CGFloat = 0.5
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(fill, in: shape).overlay { shape.strokeBorder(stroke, lineWidth: lineWidth) }
    }
}

/// A key drawn as a keycap, e.g. "⌥" or "Space".
struct Keycap: View {
    let label: String
    var large = false

    var body: some View {
        Text(label)
            .font(.system(size: large ? 12 : 11, weight: .medium))
            .tracking(0.3)
            .foregroundStyle(.secondary)
            .padding(.horizontal, large ? 6 : 5)
            .frame(minWidth: large ? 22 : 18, minHeight: large ? 22 : 18)
            .panel(Theme.keycapFill, radius: large ? 5 : 4, stroke: Theme.keycapEdge)
    }
}

/// A shortcut as separate keycaps (large) or as one compact keycap.
struct HotkeyKeycaps: View {
    let hotkey: Hotkey
    var large = false

    var body: some View {
        Group {
            if large {
                HStack(spacing: 3) {
                    ForEach(Array(hotkey.keycaps.enumerated()), id: \.offset) { _, key in
                        Keycap(label: key, large: true)
                    }
                }
            } else {
                Keycap(label: hotkey.displayString)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hotkey.spokenName)
    }
}

struct TierBadge: View {
    let tier: AnswerTier

    var body: some View {
        Label(tier.title, systemImage: tier.symbol)
            .labelStyle(CompactLabelStyle(spacing: 4))
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(tier.tint)
            .padding(.leading, 7)
            .padding(.trailing, 8)
            .frame(height: 20)
            .background(tier.tint.opacity(0.16), in: Capsule())
            .accessibilityLabel(tier.hotkeyAction.title)
    }
}

struct CompactLabelStyle: LabelStyle {
    var spacing: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
                .imageScale(.small)
            configuration.title
        }
    }
}

/// A filled capsule that keeps its colour. The window is never key, and macOS draws
/// `.borderedProminent` buttons grey in a window that is not key.
struct FilledButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        CapsuleButton(configuration: configuration, fill: tint, foreground: .white, small: small)
    }
}

/// The quieter capsule for secondary actions, such as Stop or Show in Finder.
struct SoftButtonStyle: ButtonStyle {
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        CapsuleButton(configuration: configuration, fill: Theme.strongFill, foreground: .primary, small: small)
    }
}

private struct CapsuleButton: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    let foreground: Color
    let small: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .labelStyle(CompactLabelStyle(spacing: small ? 5 : 6))
            .font(.system(size: small ? 12 : 13, weight: small ? .medium : .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? 10 : 14)
            .frame(height: small ? 24 : 28)
            .background(fill, in: Capsule())
            .overlay {
                if configuration.isPressed {
                    Capsule().fill(.black.opacity(0.12))
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A round, borderless icon button that shows a soft fill on hover.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        HoverCircle(configuration: configuration, size: size)
    }
}

private struct HoverCircle: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: size > 24 ? 11 : 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(
                Theme.strongFill.opacity(isEnabled && (hovering || configuration.isPressed) ? 1 : 0), in: Circle()
            )
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}

/// Quiet text in a soft rounded fill on hover, for the footer's answer buttons.
struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRoundedRect(configuration: configuration)
    }
}

private struct HoverRoundedRect: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(
                Theme.strongFill.opacity(isEnabled && (hovering || configuration.isPressed) ? 1 : 0),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? 1 : 0.55)
            .onHover { hovering = $0 }
    }
}

/// Text-only button in the accent colour, for actions inside banners and lists.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tint)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}
