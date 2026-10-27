import ListenerCore
import SwiftUI

/// The floating window, top to bottom: listening state and Start/Stop, the answer card
/// (or how the last call ended), banners, the transcript or what to do before a call,
/// and the cost and hotkeys. Banners go under the card so they never move an answer
/// while it is read.
///
/// During a call it is only the bar and the answer card, sized to fit, unless the
/// transcript is turned on: on a single screen anything more is in the way.
struct ListenerWindowView: View {
    let model: CallModel
    let room: PanelRoom
    let hide: @MainActor () -> Void
    /// Opens the main window, on a saved call when given its folder.
    let showMain: @MainActor (URL?) -> Void
    /// The height the compact window needs, or nil for the full window.
    let fitHeight: @MainActor (CGFloat?) -> Void

    var body: some View {
        Group {
            if model.isCompact {
                // The window's minimum size is measured at no width at all, where a
                // banner's words would stack one per line into a window taller than the
                // screen. It is never narrower than this.
                CompactCallView(model: model, room: room, hide: hide, showMain: showMain)
                    .frame(minWidth: 320)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        fitHeight(height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 0) {
                    HeaderBar(model: model, hide: hide, showMain: showMain)
                    Hairline()
                    WindowContent(model: model, showMain: showMain)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Hairline()
                    FooterBar(model: model)
                }
                .frame(minWidth: 320, minHeight: 360)
                .onAppear {
                    fitHeight(nil)
                }
            }
        }
        .background { WindowBackground(transparency: model.transparency) }
        .onHover { model.pointerMoved(over: $0) }
    }
}

/// What the window draws behind its content: Solid's fill and Clear's tint, and the edge
/// that keeps Solid and Glass apart from a page of the same colour. The glass itself is
/// AppKit's.
private struct WindowBackground: View {
    let transparency: WindowTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.windowRadius, style: .continuous)
        switch transparency {
        case .solid:
            shape.fill(Theme.windowBackground)
                .overlay { shape.strokeBorder(Theme.windowEdge, lineWidth: 1) }
        case .glass:
            shape.strokeBorder(Theme.windowEdge, lineWidth: 1)
        case .clear:
            shape.fill(Theme.clearTint)
        }
    }
}

/// The bar, the answer card when there is one, then any banners.
private struct CompactCallView: View {
    let model: CallModel
    let room: PanelRoom
    let hide: @MainActor () -> Void
    let showMain: @MainActor (URL?) -> Void
    @State private var noticesHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model, hide: hide, showMain: showMain)
            if let id = model.answerID {
                AnswerCardView(model: model, maxTextHeight: maxTextHeight)
                    .id(id)
                    .padding(.horizontal, Theme.cardInset)
                    .padding(.bottom, Theme.cardInset)
            }
            NoticeStack(model: model)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    noticesHeight = height
                }
        }
    }

    /// A recap or a deep answer gets all the screen below the bar that the card's own
    /// header and the banners leave, so it is cut short only when the screen runs out.
    private var maxTextHeight: CGFloat {
        max(160, room.height - Theme.headerHeight - AnswerCardView.chromeHeight - Theme.cardInset - noticesHeight)
    }
}

/// The card above the transcript (the answer while there is one, otherwise progress
/// while saving and the saved call afterwards), then the transcript or an empty state.
///
/// The card sits on top so that a streaming answer grows downwards: its words never
/// move while being read, and the transcript keeps its newest line at the bottom.
private struct WindowContent: View {
    private enum Card: Equatable {
        case none
        case answer(Int)
        case outcome
    }

    let model: CallModel
    let showMain: @MainActor (URL?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                switch card {
                case .none:
                    EmptyView()
                case .answer(let id):
                    AnswerCardView(model: model, maxTextHeight: max(proxy.size.height * 0.5, 140))
                        .id(id)
                        .modifier(CardPlacement(reduceMotion: reduceMotion))
                case .outcome:
                    CallOutcomeCard(model: model, showMain: showMain)
                        .modifier(CardPlacement(reduceMotion: reduceMotion))
                }
                NoticeStack(model: model, spacingAbove: card == .none ? 8 : 4)
                MainContent(model: model)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.1), value: card)
        }
    }

    /// Once the call has stopped, how it was saved matters more than its last answer.
    private var card: Card {
        switch model.phase {
        case .stopping:
            return .outcome
        case .finished:
            return model.outcome == nil ? .none : .outcome
        case .idle, .starting, .listening:
            return model.answerID.map(Card.answer) ?? .none
        }
    }
}

private struct CardPlacement: ViewModifier {
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Theme.cardInset)
            .padding(.top, 8)
            .padding(.bottom, 6)
            // Words must be readable from the first frame, so a card slides in a few
            // points but is never faded in.
            .transition(reduceMotion ? .identity : .asymmetric(insertion: .offset(y: -8), removal: .opacity))
    }
}

private struct MainContent: View {
    let model: CallModel

    var body: some View {
        if model.hasTranscript {
            TranscriptView(model: model)
        } else {
            switch model.phase {
            case .idle, .finished:
                SetupView(model: model)
            case .starting:
                EmptyStateView(
                    title: "Starting", message: "Connecting to the microphone and system audio.", model: model)
            case .listening:
                EmptyStateView(
                    title: "Listening", message: "The transcript appears here as people speak.\(callLine)",
                    model: model, showsHearing: true)
            case .stopping:
                EmptyStateView(title: "Nothing was said", message: "Saving the call.", model: model)
            }
        }
    }
}

extension MainContent {
    /// Which call type and background the call started with, e.g. "Work call, with 2 documents".
    fileprivate var callLine: String {
        guard let call = model.activeCall, !call.callType.isEmpty else {
            return ""
        }
        switch call.documents.count {
        case 0: return "\n\(call.callType)."
        case 1: return "\n\(call.callType), with 1 document."
        default: return "\n\(call.callType), with \(call.documents.count) documents."
        }
    }
}

private struct HeaderBar: View {
    let model: CallModel
    let hide: @MainActor () -> Void
    let showMain: @MainActor (URL?) -> Void

    var body: some View {
        HStack(spacing: 4) {
            if model.isInCall {
                RecordingChip(model: model)
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    AnswerSwitcher(model: model, titled: true)
                    AnswerSwitcher(model: model, titled: false)
                    Color.clear.frame(width: 0, height: 0)
                }
                Button(action: model.toggleTranscriptInCall) {
                    Image(systemName: "text.alignleft")
                }
                .buttonStyle(IconButtonStyle(isOn: model.showsTranscriptInCall))
                .help(model.showsTranscriptInCall ? "Hide the transcript" : "Show the transcript")
                .accessibilityLabel(model.showsTranscriptInCall ? "Hide the transcript" : "Show the transcript")
                StopButton(model: model)
            } else {
                AppMark()
                    .padding(.trailing, 5)
                Text("Listener")
                    .font(.geist(13.5, .semibold))
                    .tracking(-0.1)
                Circle()
                    .fill(Theme.strongBorder)
                    .frame(width: 3, height: 3)
                    .padding(.horizontal, 5)
                IdleStatus(model: model)
                Spacer(minLength: 8)
                StartButton(model: model)
                    .padding(.trailing, 2)
                Button {
                    showMain(nil)
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(IconButtonStyle())
                .help("Open Listener: your calls, call types, dictionary and settings")
                .accessibilityLabel("Open Listener")
            }
            Button(action: hide) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: model.isInCall ? 24 : 28))
            .help("Hide the window. Show it again from the menu bar.")
            .accessibilityLabel("Hide window")
        }
        .padding(.leading, model.isInCall ? 11 : 14)
        .padding(.trailing, 8)
        .frame(height: Theme.headerHeight)
        .background(WindowDragArea())
    }
}

/// Quick, Deep and Recap, with the answer on screen picked out. Icons only when the
/// window is narrow, and left out when it is narrower still; the hotkeys and the menu
/// still work.
private struct AnswerSwitcher: View {
    let model: CallModel
    let titled: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AnswerTier.allCases, id: \.self) { tier in
                let hotkey = model.activeHotkeys[tier.hotkeyAction]
                let name = tier.hotkeyAction.title
                let isOn = model.answer?.tier == tier
                Button {
                    model.ask(tier)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tier.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isOn ? Theme.accentText : Theme.tertiaryText)
                        if titled {
                            Text(tier.title)
                        }
                    }
                }
                .buttonStyle(SwitcherStyle(isOn: isOn))
                .disabled(!model.canAsk)
                .help(hotkey.map { "\(name): \($0.displayString)" } ?? name)
                .accessibilityLabel(name)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
        .fixedSize()
    }
}

private struct SwitcherStyle: ButtonStyle {
    let isOn: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .font(.geist(12, .medium))
            .foregroundStyle(isOn || hovering ? Theme.text : Theme.secondaryText)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(isOn ? Theme.raised : configuration.isPressed ? Theme.hover : .clear, in: shape)
            .overlay {
                if isOn {
                    shape.strokeBorder(Theme.highlight, lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(isOn ? 0.2 : 0), radius: 1, y: 1)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
}

/// Whether audio is being captured, which must be obvious at a glance: a red chip with
/// a pulsing dot and the call's length.
private struct RecordingChip: View {
    let model: CallModel

    var body: some View {
        HStack(spacing: 4) {
            if model.phase == .listening {
                // Room for the halo at its widest, so it is never clipped.
                ListeningPulse()
                    .frame(width: 18, height: 18)
                if let since = model.listeningSince {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(DisplayFormat.clock(context.date.timeIntervalSince(since)))
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 18, height: 18)
                Text(model.phase == .stopping ? "Saving" : "Starting")
                    .font(.geist(12.5, .medium))
            }
        }
        .font(.geistMono(12.5, .medium))
        .foregroundStyle(model.phase == .listening ? Theme.recordingText : Theme.secondaryText)
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(height: 28)
        .background(
            model.phase == .listening ? Theme.recordingTint : Theme.hover,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(model.phase == .listening ? Theme.recording.opacity(0.25) : Theme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.phase == .listening ? "Listening: audio is being captured" : "Starting")
    }
}

private struct IdleStatus: View {
    let model: CallModel

    var body: some View {
        Group {
            switch model.phase {
            case .starting:
                Text("Starting…")
            case .stopping:
                Text("Saving…")
            case .idle, .finished, .listening:
                Text(Readiness.blocksStart(model.readiness) ? "Set up needed" : "Ready")
            }
        }
        .font(.geist(12.5, .medium))
        .foregroundStyle(Theme.tertiaryText)
        .lineLimit(1)
    }
}

private struct StartButton: View {
    let model: CallModel

    var body: some View {
        Button(action: model.start) {
            HStack(spacing: 7) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("Start")
                if let hotkey = model.activeHotkeys[.toggleListening] {
                    HotkeyKeycaps(hotkey: hotkey, onAccent: true)
                        .padding(.trailing, -5)
                }
            }
        }
        .buttonStyle(FilledButtonStyle())
        .disabled(!(model.phase == .idle || model.phase == .finished))
        .help(
            model.activeHotkeys[.toggleListening].map { "Start listening (\($0.displayString))" } ?? "Start listening"
        )
        .accessibilityLabel("Start listening")
        .accessibilityHint(model.activeHotkeys[.toggleListening].map { "Shortcut: \($0.spokenName)" } ?? "")
    }
}

private struct StopButton: View {
    let model: CallModel

    var body: some View {
        Button(action: model.stop) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.recording)
                .frame(width: 9, height: 9)
                .frame(width: 28, height: 28)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.phase != .listening)
        .help(
            model.activeHotkeys[.toggleListening].map { "Stop listening and save the call (\($0.displayString))" }
                ?? "Stop listening and save the call"
        )
        .accessibilityLabel("Stop listening")
        .accessibilityHint(model.activeHotkeys[.toggleListening].map { "Shortcut: \($0.spokenName)" } ?? "")
    }
}

private struct NoticeStack: View {
    let model: CallModel
    var spacingAbove: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let appNotices = model.appNotices.items
        let callNotices = model.callNotices
        VStack(spacing: 6) {
            ForEach(appNotices) { notice in
                NoticeBanner(notice: notice, perform: model.perform) { model.dismissAppNotice(notice) }
            }
            ForEach(callNotices) { notice in
                NoticeBanner(notice: notice, perform: model.perform) { model.dismissNotice(notice) }
            }
        }
        .padding(.horizontal, Theme.cardInset)
        .padding(.top, appNotices.isEmpty && callNotices.isEmpty ? 0 : spacingAbove)
        .padding(.bottom, appNotices.isEmpty && callNotices.isEmpty ? 0 : 8)
        .animation(
            reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.1),
            value: appNotices.map(\.id) + callNotices.map(\.id))
    }
}

private struct NoticeBanner: View {
    let notice: Notice
    let perform: @MainActor (NoticeAction) -> Void
    let dismiss: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12.5))
                .foregroundStyle(tint)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(notice.message)
                    .font(.geist(12.5))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.proseText)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = notice.action {
                    Button(action.title) { perform(action) }
                        .buttonStyle(LinkButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 20))
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 9)
        .panel(
            notice.kind == .error ? Theme.danger.opacity(0.1) : Theme.surface, radius: Theme.bannerRadius,
            stroke: notice.kind == .error ? Theme.danger.opacity(0.25) : Theme.border
        )
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kindName): \(notice.message)")
    }

    private var kindName: String {
        switch notice.kind {
        case .info: "Note"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    private var symbol: String {
        switch notice.kind {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .info: Theme.accentText
        case .warning: Theme.amber
        case .error: Theme.danger
        }
    }
}

private struct FooterBar: View {
    let model: CallModel

    var body: some View {
        HStack(spacing: 12) {
            if model.phase != .idle || model.cost.total > 0 {
                Text(DisplayFormat.cost(model.cost.total))
                    .font(.geistMono(11))
                    .help(costDetail)
                    .accessibilityLabel("Cost of this call: \(DisplayFormat.cost(model.cost.total))")
            }
            if let latency = model.lastLatencyMs {
                Label(DisplayFormat.latency(milliseconds: latency), systemImage: "timer")
                    .labelStyle(CompactLabelStyle(spacing: 4))
                    .font(.geistMono(11))
                    .help("Time from the hotkey to the first word of the last answer")
                    .accessibilityLabel("Last answer started in \(DisplayFormat.latency(milliseconds: latency))")
            }
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                hotkeyHints(titled: true)
                hotkeyHints(titled: false)
            }
        }
        .font(.geist(11.5))
        .foregroundStyle(Theme.tertiaryText)
        .lineLimit(1)
        .padding(.leading, Theme.gutter)
        // The buttons' hover fill reaches 6 points past their text.
        .padding(.trailing, 8)
        .frame(height: Theme.footerHeight)
        .background(WindowDragArea())
    }

    private var costDetail: String {
        let cost = model.cost
        return
            "Speech to text \(DisplayFormat.cost(cost.speechCost)), Claude \(DisplayFormat.cost(cost.modelCost))"
    }

    private func hotkeyHints(titled: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(AnswerTier.allCases, id: \.self) { tier in
                hint(tier, titled: titled)
            }
        }
    }

    /// A button for each tier, with its hotkey when it is registered.
    private func hint(_ tier: AnswerTier, titled: Bool) -> some View {
        let hotkey = model.activeHotkeys[tier.hotkeyAction]
        let name = tier.hotkeyAction.title
        return Button {
            model.ask(tier)
        } label: {
            HStack(spacing: 5) {
                if let hotkey {
                    HotkeyKeycaps(hotkey: hotkey)
                }
                if titled || hotkey == nil {
                    Text(tier.title)
                }
            }
        }
        .buttonStyle(FooterButtonStyle())
        .disabled(!model.canAsk)
        .help(hotkey.map { "\(name): \($0.displayString)" } ?? name)
        .accessibilityLabel(hotkey.map { "\(name): \($0.spokenName)" } ?? name)
    }
}
