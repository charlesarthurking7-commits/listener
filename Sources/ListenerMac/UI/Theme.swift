import AppKit
import ListenerCore
import SwiftUI

/// The design tokens: a 4 pt grid, near-black or near-white grounds with hairline edges,
/// one indigo accent, red only for recording and amber only for what is meant for the
/// user alone. Every colour follows light and dark mode, and text colours pass 4.5:1 on
/// the surfaces they sit on.
enum Theme {
    // MARK: Grounds

    static let windowBackground = Color.adaptive(light: rgb(0xFBFBFA), dark: rgb(0x0F0F12))
    static let sidebarBackground = Color.adaptive(light: rgb(0xF3F3F2), dark: rgb(0x0B0B0E))
    /// Cards and panels on the window.
    static let surface = Color.adaptive(light: rgb(0xFFFFFF), dark: rgb(0x151519))
    /// What is picked: a list row, the on segment of a switch.
    static let raised = Color.adaptive(light: rgb(0xFFFFFF), dark: rgb(0x1E1E23))
    /// The face of a secondary button or a menu.
    static let control = Color.adaptive(light: rgb(0xFFFFFF), dark: rgb(0x1C1C21))
    static let controlPressed = Color.adaptive(light: rgb(0xF0F0F1), dark: rgb(0x26262C))
    /// The track of a segmented control or a search field.
    static let well = Color.adaptive(light: rgb(0xEFEFF0), dark: rgb(0x17171B))
    static let hover = Color.adaptive(light: rgb(0x000000, 0.04), dark: rgb(0xFFFFFF, 0.05))
    static let selection = Color.adaptive(light: rgb(0x000000, 0.06), dark: rgb(0xFFFFFF, 0.07))

    // MARK: Edges

    static let border = Color.adaptive(light: rgb(0x000000, 0.08), dark: rgb(0xFFFFFF, 0.07))
    static let strongBorder = Color.adaptive(light: rgb(0x000000, 0.12), dark: rgb(0xFFFFFF, 0.11))
    static let hairline = Color.adaptive(light: rgb(0x000000, 0.06), dark: rgb(0xFFFFFF, 0.06))
    /// The window's own edge: enough to separate it from a page of the same colour.
    static let windowEdge = Color.adaptive(light: rgb(0x000000, 0.12), dark: rgb(0xFFFFFF, 0.1))
    /// The light catching a control's top edge in dark mode.
    static let highlight = Color.adaptive(light: rgb(0xFFFFFF, 0), dark: rgb(0xFFFFFF, 0.04))

    // MARK: Text

    static let text = Color.adaptive(light: rgb(0x18181B), dark: rgb(0xEDEDEF))
    /// Paragraphs: a touch softer than headings, so long text is easy on the eye.
    static let proseText = Color.adaptive(light: rgb(0x27272A), dark: rgb(0xD4D4D8))
    static let secondaryText = Color.adaptive(light: rgb(0x52525B), dark: rgb(0xA0A0AB))
    static let tertiaryText = Color.adaptive(light: rgb(0x6B6B73), dark: rgb(0x8A8A94))

    // MARK: Colour that means something

    static let accent = Color(nsColor: rgb(0x625EF0))
    /// The accent as text or an icon on the window's ground.
    static let accentText = Color.adaptive(light: rgb(0x504DC5), dark: rgb(0xA9A7F6))
    static let accentTint = Color.adaptive(light: rgb(0x625EF0, 0.1), dark: rgb(0x625EF0, 0.16))
    static let recording = Color.adaptive(light: rgb(0xDC2626), dark: rgb(0xFF4D4F))
    static let recordingText = Color.adaptive(light: rgb(0xB91C1C), dark: rgb(0xFF8A8C))
    static let recordingTint = Color.adaptive(light: rgb(0xDC2626, 0.07), dark: rgb(0xFF4D4F, 0.1))
    static let ready = Color.adaptive(light: rgb(0x16A34A), dark: rgb(0x3FCF8E))
    static let danger = Color.adaptive(light: rgb(0xDC2626), dark: rgb(0xFF6B6B))
    /// Notes meant only for the user, and the other side of the call.
    static let amber = Color.adaptive(light: rgb(0xB45309), dark: rgb(0xF2B36A))
    static let noteFill = Color.adaptive(light: rgb(0xFFF7EA), dark: rgb(0xF2B36A, 0.07))
    static let noteBorder = Color.adaptive(light: rgb(0xB45309, 0.16), dark: rgb(0xF2B36A, 0.16))
    /// Clear's whole background: dark enough under light text to read over video or a
    /// busy desktop, light enough to see through.
    static let clearTint = Color.black.opacity(0.42)

    // MARK: Type

    static let transcriptFont = Font.geist(14)
    static let transcriptLineSpacing: CGFloat = 4
    static let answerSize: CGFloat = 17
    static let answerFont = Font.geist(answerSize)
    static let answerLineSpacing: CGFloat = 5
    static let metaFont = Font.geistMono(11)
    static let labelFont = Font.geist(10.5, .semibold)

    // MARK: Layout

    static let gutter: CGFloat = 16
    static let headerHeight: CGFloat = 52
    static let footerHeight: CGFloat = 36
    static let cardRadius: CGFloat = 12
    static let windowRadius: CGFloat = 16
    static let bannerRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8
    static let cardInset: CGFloat = 12

    // The floating window's older names for the tokens above.
    static let cardFill = surface
    static let cardStroke = border
    static let fill = hover
    static let strongFill = selection
    static let keycapFill = Color.adaptive(light: rgb(0xF4F4F5), dark: rgb(0xFFFFFF, 0.05))
    static let keycapEdge = Color.adaptive(light: rgb(0x000000, 0.1), dark: rgb(0xFFFFFF, 0.08))
    static let noteLabel = amber

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
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
    /// The accent for the user, amber for the other side.
    var tint: Color {
        switch self {
        case .me: Theme.accentText
        case .them: Theme.amber
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

    /// One accent for every tier: the label and the icon tell them apart.
    var tint: Color { Theme.accentText }
}

/// A one-pixel separator at any display scale.
struct Hairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1 / displayScale)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A rounded panel behind the view, `fill` inside a hairline `stroke`.
    func panel(
        _ fill: Color = Theme.surface, radius: CGFloat = Theme.cardRadius, stroke: Color = Theme.border,
        lineWidth: CGFloat = 1
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(fill, in: shape).overlay { shape.strokeBorder(stroke, lineWidth: lineWidth) }
    }
}

/// A small uppercase heading over a group, e.g. "THIS CALL".
struct SectionLabel: View {
    let text: String
    var tint = Theme.tertiaryText

    init(_ text: String, tint: Color = Theme.tertiaryText) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(Theme.labelFont)
            .tracking(0.85)
            .textCase(.uppercase)
            .foregroundStyle(tint)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A key drawn as a keycap, e.g. "⌥" or "⌃⌥L".
struct Keycap: View {
    let label: String
    var large = false
    /// On an accent button, where the usual keycap would be invisible.
    var onAccent = false

    var body: some View {
        Text(label)
            .font(.geistMono(large ? 11.5 : 10.5, .medium))
            .foregroundStyle(onAccent ? Color.white.opacity(0.92) : Theme.secondaryText)
            .padding(.horizontal, 5)
            .frame(minWidth: large ? 22 : 18, minHeight: large ? 22 : 18)
            .background(
                onAccent ? Color.white.opacity(0.17) : Theme.keycapFill,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay {
                if !onAccent {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.keycapEdge, lineWidth: 1)
                }
            }
    }
}

/// A shortcut as separate keycaps (large) or as one compact keycap.
struct HotkeyKeycaps: View {
    let hotkey: Hotkey
    var large = false
    var onAccent = false

    var body: some View {
        Group {
            if large {
                HStack(spacing: 3) {
                    ForEach(Array(hotkey.keycaps.enumerated()), id: \.offset) { _, key in
                        Keycap(label: key, large: true, onAccent: onAccent)
                    }
                }
            } else {
                Keycap(label: hotkey.displayString, onAccent: onAccent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hotkey.spokenName)
    }
}

/// The answer's kind, as a small tinted chip with its icon.
struct TierBadge: View {
    let tier: AnswerTier

    var body: some View {
        Label(tier.title, systemImage: tier.symbol)
            .labelStyle(CompactLabelStyle(spacing: 5))
            .font(.geist(11.5, .semibold))
            .foregroundStyle(Theme.accentText)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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

/// The one accent button on a screen. The window is often not key, and macOS draws
/// `.borderedProminent` buttons grey in a window that is not key, so this keeps its colour.
struct FilledButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        ControlButton(configuration: configuration, kind: .filled(tint), small: small)
    }
}

/// The quieter button for everything else, such as Stop or Show in Finder.
struct SoftButtonStyle: ButtonStyle {
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        ControlButton(configuration: configuration, kind: .soft, small: small)
    }
}

private struct ControlButton: View {
    enum Kind {
        case filled(Color)
        case soft
    }

    let configuration: ButtonStyleConfiguration
    let kind: Kind
    let small: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: small ? 7 : Theme.controlRadius, style: .continuous)
        configuration.label
            .labelStyle(CompactLabelStyle(spacing: small ? 5 : 6))
            .font(.geist(small ? 12 : 12.5, filled ? .semibold : .medium))
            .foregroundStyle(filled ? Color.white : Theme.text)
            .padding(.horizontal, small ? 9 : 11)
            .frame(height: small ? 26 : 28)
            .background(background, in: shape)
            .overlay {
                if filled {
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center),
                        lineWidth: 1)
                } else {
                    shape.strokeBorder(Theme.border, lineWidth: 1)
                }
            }
            .overlay {
                if configuration.isPressed && filled {
                    shape.fill(.black.opacity(0.14))
                }
            }
            .shadow(color: .black.opacity(filled ? 0.25 : 0.06), radius: 1, y: 1)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }

    private var filled: Bool {
        if case .filled = kind {
            return true
        }
        return false
    }

    private var background: Color {
        switch kind {
        case .filled(let tint):
            tint
        case .soft:
            configuration.isPressed || (hovering && isEnabled) ? Theme.controlPressed : Theme.control
        }
    }
}

/// A square, borderless icon button that shows a soft fill on hover.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    /// Drawn as switched on, e.g. the transcript while it shows.
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        HoverSquare(configuration: configuration, size: size, isOn: isOn)
    }
}

private struct HoverSquare: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let isOn: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size > 24 ? 7 : 6, style: .continuous)
        configuration.label
            .font(.system(size: size > 24 ? 12 : 11, weight: .semibold))
            .foregroundStyle(isOn || hovering ? Theme.text : Theme.tertiaryText)
            .frame(width: size, height: size)
            .background(
                isOn || (isEnabled && (hovering || configuration.isPressed)) ? Theme.selection : .clear, in: shape
            )
            .contentShape(shape)
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
                Theme.selection.opacity(isEnabled && (hovering || configuration.isPressed) ? 1 : 0),
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
            .font(.geist(12, .semibold))
            .foregroundStyle(Theme.accentText)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}
