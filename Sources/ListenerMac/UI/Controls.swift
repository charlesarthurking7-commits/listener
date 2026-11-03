import SwiftUI

/// Round chips that pick one of a few: the picked one filled with ink, the rest soft.
struct Chips<Value: Hashable>: View {
    struct Option {
        var value: Value
        var title: String
        /// A count after the title, e.g. the number of answers.
        var count: Int?
    }

    let options: [Option]
    @Binding var selection: Value
    var label: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 5) {
                        Text(option.title)
                        if let count = option.count {
                            Text("\(count)")
                                .monospacedDigit()
                                .opacity(0.6)
                        }
                    }
                }
                .buttonStyle(ChipStyle(isOn: option.value == selection))
                .accessibilityAddTraits(option.value == selection ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

private struct ChipStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, isOn: isOn)
    }
}

private struct Chip: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.geist(13, .medium))
            .foregroundStyle(isOn ? Theme.onInk : Theme.text)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(isOn ? Theme.ink : Theme.selection, in: Capsule())
            .overlay {
                if !isOn && (hovering || configuration.isPressed) {
                    Capsule().fill(Theme.hover)
                }
            }
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

/// The main window's buttons: an ink pill for the one thing to do, soft grey pills for
/// the rest.
struct PillButtonStyle: ButtonStyle {
    enum Kind {
        case ink
        case soft
    }

    var kind = Kind.soft
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, kind: kind, small: small)
    }
}

private struct Pill: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind
    let small: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .labelStyle(CompactLabelStyle(spacing: small ? 5 : 7))
            .font(.geist(small ? 12.5 : 13, .medium))
            .foregroundStyle(kind == .ink ? Theme.onInk : Theme.text)
            .padding(.horizontal, small ? 12 : 15)
            .frame(height: small ? 28 : 32)
            .background(kind == .ink ? Theme.ink : Theme.selection, in: Capsule())
            .overlay {
                if hovering && isEnabled || configuration.isPressed {
                    Capsule().fill(kind == .ink ? Theme.onInk.opacity(0.12) : Theme.hover)
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// A tile on the main window's canvas: white in light mode, a lifted grey in the dark,
    /// with no edge.
    func tile(radius: CGFloat = 18) -> some View {
        background(Theme.tile, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Set as a title or heading: semibold Geist, tighter the larger it is.
    func heading(_ size: CGFloat) -> some View {
        font(.geist(size, .semibold)).tracking(-size * 0.022)
    }
}

/// A heading over a tile, with a count or a button on the right.
struct SectionHeading<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .heading(18)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory()
                .font(.geist(13))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 10)
    }
}

extension SectionHeading where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// An icon or a letter in a soft circle at the start of a row.
struct RoundGlyph: View {
    var symbol: String?
    var letter: String?
    var size: CGFloat = 36

    var body: some View {
        Circle()
            .fill(Theme.selection)
            .overlay {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.39, weight: .medium))
                } else if let letter {
                    Text(letter)
                        .font(.geist(size * 0.42, .semibold))
                }
            }
            .foregroundStyle(Theme.secondaryText)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A list row's ground: a soft fill while it is picked, a fainter one on hover.
    func rowBackground(isOn: Bool, hovering: Bool, radius: CGFloat = 10) -> some View {
        background(
            isOn ? Theme.selection : hovering ? Theme.hover : .clear,
            in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A round tick box, filled with ink once ticked.
struct Checkbox: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .fill(isOn ? Theme.ink : .clear)
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.onInk)
                } else {
                    Circle().strokeBorder(Theme.tertiaryText.opacity(0.6), lineWidth: 1.5)
                }
            }
            .frame(width: 17, height: 17)
            .accessibilityHidden(true)
    }
}

/// An on and off switch in ink.
struct SwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 14) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                Capsule()
                    .fill(configuration.isOn ? Theme.ink : Theme.tertiaryText.opacity(0.35))
                    .frame(width: 30, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                            .padding(2)
                    }
                    .animation(.snappy(duration: 0.15), value: configuration.isOn)
                    .padding(.top, 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A pop-up menu drawn like the window's other controls: its value and a chevron.
struct SelectMenu<Content: View>: View {
    let title: String
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(SelectButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(title)
    }
}

private struct SelectButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(12.5, .medium))
            .foregroundStyle(Theme.text)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(height: 28)
            .background(Theme.selection, in: Capsule())
            .overlay {
                if configuration.isPressed || hovering {
                    Capsule().fill(Theme.hover)
                }
            }
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

/// A text field with a magnifying glass and a clear button, on a round tile.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var shortcut: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(focused ? Theme.secondaryText : Theme.tertiaryText)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.geist(13))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityLabel("Clear the search")
            } else if let shortcut {
                Keycap(label: shortcut)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 36)
        .background(Theme.tile, in: Capsule())
        .overlay { Capsule().strokeBorder(focused ? Theme.ink.opacity(0.35) : .clear, lineWidth: 1) }
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// Multi-line text that saves as it is typed, on a tile.
struct TextArea: View {
    @Binding var text: String
    var label: String
    var prompt: String?
    var minHeight: CGFloat = 96
    var font: Font = .geist(13.5)
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        TextEditor(text: $text)
            .font(font)
            .foregroundStyle(Theme.text)
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.automatic)
            .focused($focused)
            .padding(.horizontal, 13)
            .padding(.vertical, 14)
            .frame(minHeight: minHeight)
            .background(Theme.tile, in: shape)
            .overlay(alignment: .topLeading) {
                if let prompt, text.isEmpty {
                    Text(prompt)
                        .font(font)
                        .lineSpacing(3)
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .overlay { shape.strokeBorder(focused ? Theme.ink.opacity(0.35) : .clear, lineWidth: 1) }
            .accessibilityLabel(label)
    }
}

extension View {
    /// A card on the window: the surface colour inside a hairline, with rounded corners.
    func card(radius: CGFloat = Theme.cardRadius) -> some View {
        panel(Theme.surface, radius: radius, stroke: Theme.border)
    }
}

/// Listener's mark, as the app icon draws it at 32 px (scripts/make-icon.py): an L cut
/// into five lines, the last slid out from under it in indigo, on ink. Drawn rather than
/// an image so it stays sharp at any size.
struct AppMark: View {
    var size: CGFloat = 22

    private static let ink = Color(.sRGB, red: 0x0C / 255, green: 0x0F / 255, blue: 0x17 / 255)
    private static let line = Color(.sRGB, red: 0xF3 / 255, green: 0xF4 / 255, blue: 0xF7 / 255)
    private static let indigo = Color(.sRGB, red: 0x7D / 255, green: 0x7A / 255, blue: 0xFF / 255)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        shape
            .fill(Self.ink)
            .overlay {
                Canvas { context, canvas in
                    // On a 26-unit tile: lines 2 high with 1 between, the stem's 4 long,
                    // the long one 11, and the last slid 3 to the right.
                    let unit = canvas.width / 26
                    for row in 0..<5 {
                        let y = (6 + CGFloat(row) * 3) * unit
                        let x = (row == 4 ? 9 : 6) * unit
                        let length = (row >= 3 ? 11 : 4) * unit
                        context.fill(
                            Path(CGRect(x: x, y: y, width: length, height: 2 * unit)),
                            with: .color(row == 4 ? Self.indigo : Self.line))
                    }
                }
            }
            .overlay { shape.strokeBorder(.white.opacity(0.1), lineWidth: 1) }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
