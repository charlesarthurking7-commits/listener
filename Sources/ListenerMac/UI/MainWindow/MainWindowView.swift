import ListenerCore
import SwiftUI

/// The sidebar and the section it picks.
struct MainWindowView: View {
    let model: MainWindowModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            VerticalHairline()
            Group {
                switch model.section {
                case .calls:
                    CallsView(model: model.calls)
                case .callTypes:
                    CallTypesView(model: model.callTypes)
                case .dictionary:
                    DictionaryView(model: model.dictionary)
                case .settings:
                    SettingsView(model: model.settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.windowBackground)
        .tint(Theme.accent)
        .font(.geist(13))
        .foregroundStyle(Theme.text)
    }
}

struct VerticalHairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1 / displayScale)
            .accessibilityHidden(true)
    }
}

/// The bar across the top of a section: as tall as the title bar, so the window buttons
/// and the section's controls line up, and it moves the window when dragged.
struct SectionBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 8, content: content)
            .padding(.horizontal, 20)
            .frame(height: Theme.headerHeight)
            .frame(maxWidth: .infinity)
            .background(WindowDragArea())
            .overlay(alignment: .bottom) { Hairline() }
    }
}

private struct Sidebar: View {
    let model: MainWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window buttons sit here.
            Color.clear
                .frame(height: Theme.headerHeight)
                .background(WindowDragArea())
            HStack(spacing: 9) {
                AppMark()
                Text("Listener")
                    .font(.geist(14, .semibold))
                    .tracking(-0.15)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
            CallButton(model: model.call, toggle: model.toggleCall)
            if model.call.isInCall {
                AnswerButtons(call: model.call, fills: true)
                    .padding(.top, 8)
            } else {
                CallTypePicker(model: model)
                    .padding(.top, 8)
            }
            VStack(spacing: 2) {
                ForEach(MainWindowModel.Section.allCases) { section in
                    SidebarRow(section: section, count: model.count(for: section), isOn: model.section == section) {
                        model.section = section
                    }
                }
            }
            .padding(.top, 16)
            Spacer(minLength: 16)
            MonthCard(model: model.calls)
            CallStatusLine(model: model.call)
                .padding(.horizontal, 8)
                .padding(.top, 12)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: 220)
        .background(Theme.sidebarBackground)
    }
}

private struct SidebarRow: View {
    let section: MainWindowModel.Section
    let count: Int?
    let isOn: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(section.title)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.geistMono(11))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .font(.geist(13, .medium))
            .foregroundStyle(isOn || hovering ? Theme.text : Theme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                isOn ? Theme.selection : hovering ? Theme.hover : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Starts a call from the main window, or shows and stops the one that is running.
private struct CallButton: View {
    let model: CallModel
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                if model.phase == .listening {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.recording)
                        .frame(width: 9, height: 9)
                    Text("Stop call")
                    Spacer(minLength: 4)
                    if let since = model.listeningSince {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Text(DisplayFormat.clock(context.date.timeIntervalSince(since)))
                                .font(.geistMono(12, .medium))
                                .foregroundStyle(Theme.recordingText)
                        }
                    }
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.phase == .starting ? "Starting…" : model.phase == .stopping ? "Saving…" : "Start call")
                    Spacer(minLength: 4)
                    if let hotkey = model.activeHotkeys[.toggleListening] {
                        HotkeyKeycaps(hotkey: hotkey, onAccent: true)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(CallButtonStyle(listening: model.phase == .listening))
        .disabled(model.phase == .starting || model.phase == .stopping)
        .help(model.phase == .listening ? "Stop listening and save the call" : "Start listening")
    }
}

private struct CallButtonStyle: ButtonStyle {
    let listening: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        configuration.label
            .font(.geist(13, .semibold))
            .foregroundStyle(listening ? Theme.text : .white)
            .padding(.leading, 10)
            .padding(.trailing, 7)
            .frame(height: 32)
            .background(listening ? Theme.recordingTint : Theme.accent, in: shape)
            .overlay {
                shape.strokeBorder(
                    listening
                        ? AnyShapeStyle(Theme.recording.opacity(0.3))
                        : AnyShapeStyle(
                            LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center)),
                    lineWidth: 1)
            }
            .overlay {
                if configuration.isPressed {
                    shape.fill(.black.opacity(0.12))
                }
            }
            .shadow(color: .black.opacity(listening ? 0 : 0.25), radius: 1, y: 1)
            .contentShape(shape)
    }
}

/// What calls have cost on Claude this month.
private struct MonthCard: View {
    let model: CallsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("This month")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(DisplayFormat.cost(model.monthCost))
                    .font(.geistMono(18, .medium))
                    .tracking(-0.2)
                Text("on calls")
                    .font(.geist(11.5))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.top, 9)
            Text(model.monthCalls == 1 ? "1 call" : "\(model.monthCalls) calls")
                .font(.geist(11.5))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.top, 5)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(Theme.surface, radius: 10)
        .accessibilityElement(children: .combine)
    }
}

private struct CallStatusLine: View {
    let model: CallModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
            Text(text)
        }
        .font(.geist(11.5))
        .foregroundStyle(Theme.tertiaryText)
        .accessibilityElement(children: .combine)
    }

    private var dot: Color {
        switch model.phase {
        case .listening: Theme.recording
        case .starting, .stopping: Theme.amber
        case .idle, .finished: Readiness.blocksStart(model.readiness) ? Theme.amber : Theme.ready
        }
    }

    private var text: String {
        switch model.phase {
        case .listening: "Listening"
        case .starting: "Starting"
        case .stopping: "Saving the call"
        case .idle, .finished: Readiness.blocksStart(model.readiness) ? "Setup needs a look" : "Ready to listen"
        }
    }
}

/// The call type the next call starts with, picked right under Start.
private struct CallTypePicker: View {
    let model: MainWindowModel

    var body: some View {
        let call = model.call
        Menu {
            ForEach(call.callTypes, id: \.self) { name in
                Button {
                    call.selectCallType(name)
                } label: {
                    if name == call.callType {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            Divider()
            Button("Edit Call Types…") { model.section = .callTypes }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: CallTypeIcon.symbol(for: call.callType))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 16)
                Text(call.callType)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .frame(maxWidth: .infinity)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PickerButtonStyle())
        .help("The kind of call the next call is: it changes how answers go")
        .accessibilityLabel("Call type")
        .accessibilityValue(call.callType)
    }
}

private struct PickerButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        configuration.label
            .font(.geist(12.5, .medium))
            .foregroundStyle(Theme.text)
            .padding(.leading, 9)
            .padding(.trailing, 9)
            .frame(height: 30)
            .background(configuration.isPressed || hovering ? Theme.controlPressed : Theme.control, in: shape)
            .overlay { shape.strokeBorder(Theme.border, lineWidth: 1) }
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}
