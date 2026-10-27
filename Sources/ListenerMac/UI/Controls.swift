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
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .font(.geist(12, .medium))
            .foregroundStyle(isOn ? Theme.windowBackground : Theme.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(isOn ? Theme.text : .clear, in: shape)
            .overlay { shape.strokeBorder(isOn ? .clear : Theme.border, lineWidth: 1) }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.7 : 1)
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
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(font)
            .foregroundStyle(Theme.text)
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.automatic)
            .focused($focused)
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .frame(minHeight: minHeight)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topLeading) {
                if let prompt, text.isEmpty {
                    Text(prompt)
                        .font(font)
                        .lineSpacing(3)
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1)
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

/// The app's mark: three bars in an accent square, drawn rather than an image so it
/// stays sharp at any size.
/// Listener's mark, as the app icon draws it at 32 px (scripts/make-icon.py): an L cut
/// into five lines, the last slid out from under it in indigo, on ink.
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
