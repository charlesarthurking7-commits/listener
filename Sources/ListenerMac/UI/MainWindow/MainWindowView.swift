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
                case .insights:
                    InsightsView(model: model.insights)
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

/// A section's name in its bar, and a line on what it holds.
struct SectionTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        Text(title)
            .font(.geist(15, .semibold))
            .tracking(-0.15)
            .lineLimit(1)
            .layoutPriority(1)
        if let subtitle {
            Text(subtitle)
                .font(.geist(12))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
        }
    }
}

/// The sidebar keeps everything on one edge: 20 points in, the call card's contents and
/// the rows' icons included.
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
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
            CallCard(model: model)
            VStack(spacing: 2) {
                ForEach(MainWindowModel.Section.allCases) { section in
                    NavRow(
                        title: section.title, symbol: section.symbol, count: model.count(for: section),
                        isOn: model.section == section
                    ) {
                        model.section = section
                    }
                }
            }
            .padding(.top, 18)
            Spacer(minLength: 16)
            AppNotices(model: model.call)
            Hairline()
                .padding(.horizontal, -10)
            VStack(alignment: .leading, spacing: 8) {
                MonthLine(model: model.calls)
                CallStatusLine(model: model)
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 14)
        .frame(width: 220)
        .background(Theme.sidebarBackground)
    }
}

/// A place to go in a sidebar: the window's sections, or the pages of Settings.
struct NavRow: View {
    let title: String
    let symbol: String
    var count: Int?
    let isOn: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? Theme.text : Theme.tertiaryText)
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(isOn || hovering ? Theme.text : Theme.secondaryText)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.geistMono(11))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .font(.geist(13, .medium))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .rowBackground(isOn: isOn, hovering: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The next call's type and Start, together on one card. During a call the same card
/// holds the answer buttons and Stop, with Stop where Start was.
private struct CallCard: View {
    let model: MainWindowModel

    var body: some View {
        VStack(spacing: 4) {
            if model.call.isInCall {
                AnswerButtons(call: model.call, fills: true)
            } else {
                CallTypePicker(model: model)
            }
            CallButton(model: model.call)
        }
        .padding(4)
        .card()
    }
}

/// Starts a call from the main window, or shows and stops the one that is running.
private struct CallButton: View {
    let model: CallModel

    var body: some View {
        Button(action: model.toggleListening) {
            HStack(spacing: 10) {
                if model.phase == .listening {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.recording)
                        .frame(width: 9, height: 9)
                        .frame(width: 16)
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
                        .frame(width: 16)
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
            .padding(.leading, 6)
            .padding(.trailing, listening ? 10 : 6)
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
private struct MonthLine: View {
    let model: CallsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(DisplayFormat.cost(model.monthCost))
                .font(.geistMono(12.5, .medium))
                .foregroundStyle(Theme.text)
            Text(calls)
                .font(.geist(11.5))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
        }
        .help("What calls have cost on Claude and speech to text since the 1st")
        .accessibilityElement(children: .combine)
    }

    private var calls: String {
        switch model.monthCalls {
        case 0: "on calls this month"
        case 1: "on 1 call this month"
        default: "on \(model.monthCalls) calls this month"
        }
    }
}

/// Banners about the app, such as a hotkey another app has taken or a summary that is
/// ready. They used to live in the floating window, which now only shows for calls.
private struct AppNotices: View {
    let model: CallModel

    var body: some View {
        let notices = model.appNotices.items
        if !notices.isEmpty {
            VStack(spacing: 6) {
                ForEach(notices) { notice in
                    NoticeBanner(notice: notice, perform: model.perform) { model.dismissAppNotice(notice) }
                }
            }
            .padding(.bottom, 10)
        }
    }
}

/// Whether a call can start. Until one can, it leads to the setup checklist.
private struct CallStatusLine: View {
    let model: MainWindowModel

    var body: some View {
        let blocked = !model.call.isInCall && Readiness.blocksStart(model.call.readiness)
        let line = HStack(spacing: 8) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
            Text(text)
            if blocked {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
            }
        }
        .font(.geist(11.5))
        .foregroundStyle(blocked ? Theme.secondaryText : Theme.tertiaryText)
        if blocked {
            Button {
                model.section = .calls
                model.calls.showSetup()
            } label: {
                line.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Shows what Listener still needs before a call")
            .accessibilityLabel("Setup needs a look")
        } else {
            line.accessibilityElement(children: .combine)
        }
    }

    private var dot: Color {
        switch model.call.phase {
        case .listening: Theme.recording
        case .starting, .stopping: Theme.amber
        case .idle, .finished: Readiness.blocksStart(model.call.readiness) ? Theme.amber : Theme.ready
        }
    }

    private var text: String {
        switch model.call.phase {
        case .listening: "Listening"
        case .starting: "Starting"
        case .stopping: "Saving the call"
        case .idle, .finished: Readiness.blocksStart(model.call.readiness) ? "Setup needs a look" : "Ready to listen"
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
            HStack(spacing: 10) {
                Image(systemName: CallTypeIcon.symbol(for: call.callType))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(call.callType)
                        .font(.geist(13, .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("Call type")
                        .font(.geist(11))
                        .foregroundStyle(Theme.tertiaryText)
                }
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
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(height: 40)
            .background(configuration.isPressed ? Theme.selection : hovering ? Theme.hover : .clear, in: shape)
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}
