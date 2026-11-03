import ListenerCore
import SwiftUI

/// The sidebar and the section it picks.
struct MainWindowView: View {
    let model: MainWindowModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
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
        .background(Theme.canvas)
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
    }
}

/// A section's title, set large at the top of its column, with a line on what it holds
/// under it and its controls on the right. Dragging it moves the window.
struct PageHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var inset: CGFloat = 28
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .heading(26)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.geist(13))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.horizontal, inset)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WindowDragArea())
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, inset: CGFloat = 28) {
        self.init(title: title, subtitle: subtitle, inset: inset) { EmptyView() }
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
            HStack(spacing: 10) {
                AppMark(size: 24)
                Text("Listener")
                    .heading(18)
            }
            .padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 6) {
                CallButton(model: model.call)
                if model.call.isInCall {
                    AnswerButtons(call: model.call, fills: true)
                        .padding(.top, 2)
                } else {
                    CallTypePicker(model: model)
                }
            }
            .padding(.top, 24)
            VStack(spacing: 1) {
                ForEach(MainWindowModel.Section.allCases) { section in
                    NavRow(
                        title: section.title, symbol: section.symbol, count: model.count(for: section),
                        isOn: model.section == section
                    ) {
                        model.section = section
                    }
                }
            }
            .padding(.top, 22)
            Spacer(minLength: 16)
            AppNotices(model: model.call)
            MonthFigure(model: model.calls)
                .padding(.horizontal, 14)
            CallStatusLine(model: model)
                .padding(.horizontal, 14)
                .padding(.top, 14)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 18)
        .frame(width: 220)
    }
}

/// A place to go in a sidebar: the window's sections, or the pages of Settings. The one
/// that is open sits on a tile.
struct NavRow: View {
    let title: String
    let symbol: String
    var count: Int?
    let isOn: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isOn ? Theme.text : Theme.tertiaryText)
                    .frame(width: 18)
                Text(title)
                    .font(.geist(14, isOn ? .semibold : .medium))
                    .foregroundStyle(isOn || hovering ? Theme.text : Theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.geist(12.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                isOn ? Theme.tile : hovering ? Theme.hover : .clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Starts a call from the main window, or shows and stops the one that is running, in
/// the same place.
private struct CallButton: View {
    let model: CallModel

    var body: some View {
        Button(action: model.toggleListening) {
            HStack(spacing: 10) {
                if model.phase == .listening {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.recording)
                        .frame(width: 9, height: 9)
                    Text("Stop call")
                    Spacer(minLength: 4)
                    if let since = model.listeningSince {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Text(DisplayFormat.clock(context.date.timeIntervalSince(since)))
                                .font(.geist(13, .medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.recordingText)
                        }
                    }
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.phase == .starting ? "Starting…" : model.phase == .stopping ? "Saving…" : "Start call")
                    Spacer(minLength: 4)
                    if let hotkey = model.activeHotkeys[.toggleListening] {
                        Text(hotkey.displayString)
                            .font(.geist(11.5, .medium))
                            .foregroundStyle(Theme.onInk.opacity(0.7))
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(Theme.onInk.opacity(0.13), in: Capsule())
                            .accessibilityLabel(hotkey.spokenName)
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
        configuration.label
            .font(.geist(14, .medium))
            .foregroundStyle(listening ? Theme.text : Theme.onInk)
            .padding(.leading, 14)
            .padding(.trailing, listening ? 14 : 10)
            .frame(height: 40)
            .background(listening ? Theme.recordingTint : Theme.ink, in: Capsule())
            .overlay {
                if listening {
                    Capsule().strokeBorder(Theme.recording.opacity(0.3), lineWidth: 1)
                }
            }
            .overlay {
                if configuration.isPressed {
                    Capsule().fill(.black.opacity(0.15))
                }
            }
            .contentShape(Capsule())
    }
}

/// What calls have cost on Claude and speech to text this month.
private struct MonthFigure: View {
    let model: CallsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(DisplayFormat.cost(model.monthCost))
                .heading(26)
                .monospacedDigit()
            Text(calls)
                .font(.geist(12))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
        }
        .help("What calls have cost on Claude and speech to text since the 1st")
        .accessibilityElement(children: .combine)
    }

    private var calls: String {
        switch model.monthCalls {
        case 0: "no calls this month"
        case 1: "spent on 1 call this month"
        default: "spent on \(model.monthCalls) calls this month"
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
            .padding(.bottom, 14)
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
        .font(.geist(12))
        .foregroundStyle(Theme.secondaryText)
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

/// The call type the next call starts with, under Start: "as a Work call".
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
            HStack(spacing: 5) {
                Text(article(for: call.callType))
                    .foregroundStyle(Theme.tertiaryText)
                Text(call.callType)
                    .fontWeight(.medium)
                    .underline(color: Theme.strongBorder)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .font(.geist(13))
            .foregroundStyle(Theme.text)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PickerButtonStyle())
        .fixedSize()
        .help("The kind of call the next call is: it changes how answers go")
        .accessibilityLabel("Call type")
        .accessibilityValue(call.callType)
    }

    private func article(for name: String) -> String {
        "aeiouAEIOU".contains(name.first ?? "x") ? "as an" : "as a"
    }
}

private struct PickerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
