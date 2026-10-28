import SwiftUI

/// A row of mutually exclusive choices on a recessed track, the chosen one raised.
struct SegmentedControl<Value: Hashable>: View {
    struct Option {
        var value: Value
        var title: String
        var symbol: String?
        /// A count after the title, e.g. the number of answers.
        var count: Int?
    }

    let options: [Option]
    @Binding var selection: Value
    var label: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 6) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(option.value == selection ? Theme.accentText : Theme.tertiaryText)
                        }
                        Text(option.title)
                        if let count = option.count {
                            Text("\(count)")
                                .font(.geistMono(11))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                }
                .buttonStyle(SegmentStyle(isOn: option.value == selection))
                .accessibilityAddTraits(option.value == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

private struct SegmentStyle: ButtonStyle {
    let isOn: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .font(.geist(12.5, .medium))
            .foregroundStyle(isOn || hovering ? Theme.text : Theme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(isOn ? Theme.raised : .clear, in: shape)
            .overlay {
                if isOn {
                    shape.strokeBorder(Theme.highlight, lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(isOn ? 0.18 : 0), radius: 1, y: 1)
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}

/// A filter that is on or off, e.g. a call type above the list of calls.
struct FilterChipStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        FilterChip(configuration: configuration, isOn: isOn)
    }
}

private struct FilterChip: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .font(.geist(12, .medium))
            .foregroundStyle(isOn ? Theme.accentText : hovering ? Theme.text : Theme.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(isOn ? Theme.accentTint : hovering ? Theme.hover : .clear, in: shape)
            .overlay { shape.strokeBorder(isOn ? Theme.accent.opacity(0.22) : Theme.border, lineWidth: 1) }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// A list row's ground: raised like a card while it is picked, a soft fill on hover.
    func rowBackground(isOn: Bool, hovering: Bool, radius: CGFloat = 8) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background {
            if isOn {
                shape.fill(Theme.raised)
                    .overlay { shape.strokeBorder(Theme.border, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
            } else if hovering {
                shape.fill(Theme.hover)
            }
        }
    }
}

/// A card's top line: its small heading, and a note or control on the right.
struct CardHeader<Accessory: View>: View {
    let title: String
    var tint = Theme.tertiaryText
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            SectionLabel(title, tint: tint)
            Spacer(minLength: 8)
            accessory()
                .font(.geist(11.5))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(minHeight: 18)
    }
}

extension CardHeader where Accessory == EmptyView {
    init(_ title: String, tint: Color = Theme.tertiaryText) {
        self.init(title: title, tint: tint) { EmptyView() }
    }
}

/// A card with a small heading over its content, laid out like the Insights cards.
struct TitledCard<Accessory: View, Content: View>: View {
    let title: String
    var tint = Theme.tertiaryText
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: title, tint: tint, accessory: accessory)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }
}

extension TitledCard where Accessory == EmptyView {
    init(_ title: String, tint: Color = Theme.tertiaryText, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, tint: tint, accessory: { EmptyView() }, content: content)
    }
}

/// A tick box drawn in the window's style rather than the system's.
struct Checkbox: View {
    let isOn: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4.5, style: .continuous)
        shape
            .fill(isOn ? Theme.accent : Theme.surface)
            .overlay { shape.strokeBorder(isOn ? .clear : Theme.strongBorder, lineWidth: 1.25) }
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

/// An on and off switch in the accent colour.
struct SwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 14) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                Capsule()
                    .fill(configuration.isOn ? Theme.accent : Theme.strongBorder)
                    .frame(width: 30, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
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
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .font(.geist(12.5, .medium))
            .foregroundStyle(Theme.text)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(configuration.isPressed || hovering ? Theme.controlPressed : Theme.control, in: shape)
            .overlay { shape.strokeBorder(Theme.border, lineWidth: 1) }
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}

/// A text field with a magnifying glass, a clear button, and a ring while focused.
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
                .font(.geist(12.5))
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
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(height: 32)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1)
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accent.opacity(focused ? 0.18 : 0))
                .padding(-3)
        }
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// Multi-line text that saves as it is typed, on the window's surface.
struct TextArea: View {
    @Binding var text: String
    var label: String
    var prompt: String?
    var minHeight: CGFloat = 96
    var font: Font = .geist(13.5)
    /// Off inside a card, which draws the edge itself.
    var framed = true
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        TextEditor(text: $text)
            .font(font)
            .foregroundStyle(Theme.text)
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.automatic)
            .focused($focused)
            .padding(.horizontal, framed ? 9 : 11)
            .padding(.vertical, framed ? 9 : 10)
            .frame(minHeight: minHeight)
            .background(framed ? Theme.surface : .clear, in: shape)
            .overlay(alignment: .topLeading) {
                if let prompt, text.isEmpty {
                    Text(prompt)
                        .font(font)
                        .lineSpacing(3)
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.horizontal, framed ? 14 : 16)
                        .padding(.vertical, framed ? 9 : 10)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if framed {
                    shape.strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1)
                }
            }
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
