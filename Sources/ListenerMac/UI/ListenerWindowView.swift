import ListenerCore
import SwiftUI

/// The floating window, top to bottom: listening state and Start/Stop, banners, the
/// answer card (or how the last call ended), the transcript or what to do before a
/// call, and the cost and hotkeys.
///
/// During a call it is only the bar and the answer card, sized to fit, unless the
/// transcript is turned on: on a single screen anything more is in the way.
struct ListenerWindowView: View {
    let model: CallModel
    let hide: @MainActor () -> Void
    /// The height the compact window needs, or nil for the full window.
    let fitHeight: @MainActor (CGFloat?) -> Void

    var body: some View {
        Group {
            if model.isCompact {
                CompactCallView(model: model, hide: hide)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        fitHeight(height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 0) {
                    HeaderBar(model: model, hide: hide)
                    NoticeStack(model: model)
                    Hairline()
                    WindowContent(model: model)
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
        .background(model.transparency == .clear ? Theme.clearTint : .clear)
        .onHover { model.pointerMoved(over: $0) }
    }
}

/// The bar and, when there is one, the answer card under it.
private struct CompactCallView: View {
    let model: CallModel
    let hide: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model, hide: hide)
            NoticeStack(model: model)
            if let id = model.answerID {
                AnswerCardView(model: model, maxTextHeight: 320)
                    .id(id)
                    .padding(.horizontal, Theme.cardInset)
                    .padding(.bottom, Theme.cardInset)
            }
        }
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
                    CallOutcomeCard(model: model)
                        .modifier(CardPlacement(reduceMotion: reduceMotion))
                }
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
        case .stopping, .summarizing:
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
            .padding(.bottom, 4)
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
            case .stopping, .summarizing:
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

    var body: some View {
        HStack(spacing: 8) {
            ListeningStatus(model: model)
            Spacer(minLength: 8)
            if model.isInCall {
                ViewThatFits(in: .horizontal) {
                    AnswerButtons(model: model)
                    Color.clear.frame(width: 0, height: 0)
                }
                Button(action: model.toggleTranscriptInCall) {
                    Image(systemName: model.showsTranscriptInCall ? "text.bubble.fill" : "text.bubble")
                }
                .buttonStyle(IconButtonStyle())
                .help(model.showsTranscriptInCall ? "Hide the transcript" : "Show the transcript")
                .accessibilityLabel(model.showsTranscriptInCall ? "Hide the transcript" : "Show the transcript")
            }
            StartStopButton(model: model)
            Button(action: hide) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())
            .help("Hide the window. Show it again from the menu bar.")
            .accessibilityLabel("Hide window")
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: Theme.headerHeight)
        .background(WindowDragArea())
    }
}

/// Quick, Deep and Recap as icons, for the bar during a call. Left out when the window
/// is too narrow; the hotkeys and the menu still work.
private struct AnswerButtons: View {
    let model: CallModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AnswerTier.allCases, id: \.self) { tier in
                let hotkey = model.activeHotkeys[tier.hotkeyAction]
                let name = tier.hotkeyAction.title
                Button {
                    model.ask(tier)
                } label: {
                    Image(systemName: tier.symbol)
                }
                .buttonStyle(IconButtonStyle())
                .disabled(!model.canAsk)
                .help(hotkey.map { "\(name): \($0.displayString)" } ?? name)
                .accessibilityLabel(name)
            }
        }
    }
}

/// Whether audio is being captured, which must be obvious at a glance: a red pill with
/// a pulsing dot and the call's length while listening, grey text otherwise. The header
/// of a call also holds the answer buttons, so the pill makes its point without a word.
private struct ListeningStatus: View {
    let model: CallModel

    var body: some View {
        switch model.phase {
        case .listening:
            HStack(spacing: 2) {
                // Room for the halo at its widest, so it is never clipped.
                ListeningPulse()
                    .frame(width: 20, height: 20)
                if let since = model.listeningSince {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(DisplayFormat.clock(context.date.timeIntervalSince(since)))
                            .monospacedDigit()
                    }
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.red)
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .frame(height: 28)
            .background(Color.red.opacity(0.15), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Listening: audio is being captured")
        case .starting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting…")
            }
            .modifier(IdleStatusStyle())
        case .idle, .stopping, .summarizing, .finished:
            HStack(spacing: 8) {
                Circle()
                    .fill(.tertiary)
                    .frame(width: 8, height: 8)
                Text("Not listening")
            }
            .modifier(IdleStatusStyle())
            .accessibilityElement(children: .combine)
        }
    }
}

private struct IdleStatusStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .frame(height: 28)
    }
}

private struct StartStopButton: View {
    let model: CallModel

    var body: some View {
        if model.phase == .listening {
            Button(action: model.stop) {
                Label {
                    Text("Stop")
                } icon: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.red)
                }
            }
            .buttonStyle(SoftButtonStyle())
            .help(tooltip("Stop listening and save the call"))
            .accessibilityLabel("Stop listening")
            .accessibilityHint(hint)
        } else {
            Button(action: model.start) {
                Label("Start", systemImage: "mic.fill")
            }
            .buttonStyle(FilledButtonStyle())
            .disabled(!(model.phase == .idle || model.phase == .finished))
            .help(tooltip("Start listening"))
            .accessibilityLabel("Start listening")
            .accessibilityHint(hint)
        }
    }

    private func tooltip(_ text: String) -> String {
        guard let hotkey = model.activeHotkeys[.toggleListening] else {
            return text
        }
        return "\(text) (\(hotkey.displayString))"
    }

    private var hint: String {
        model.activeHotkeys[.toggleListening].map { "Shortcut: \($0.spokenName)" } ?? ""
    }
}

private struct NoticeStack: View {
    let model: CallModel
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
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.message)
                    .font(.system(size: 13))
                    .lineSpacing(2)
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
        .background(background, in: RoundedRectangle(cornerRadius: Theme.bannerRadius, style: .continuous))
        .overlay {
            if notice.kind != .error {
                RoundedRectangle(cornerRadius: Theme.bannerRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kindName): \(notice.message)")
    }

    private var background: Color {
        notice.kind == .error ? .red.opacity(0.12) : Theme.cardFill
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
        case .info: .accentColor
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct FooterBar: View {
    let model: CallModel

    var body: some View {
        HStack(spacing: 12) {
            if model.phase != .idle || model.cost.total > 0 {
                Text(DisplayFormat.cost(model.cost.total))
                    .help(costDetail)
                    .accessibilityLabel("Cost of this call: \(DisplayFormat.cost(model.cost.total))")
            }
            if let latency = model.lastLatencyMs {
                Label(DisplayFormat.latency(milliseconds: latency), systemImage: "timer")
                    .labelStyle(CompactLabelStyle(spacing: 4))
                    .help("Time from the hotkey to the first word of the last answer")
                    .accessibilityLabel("Last answer started in \(DisplayFormat.latency(milliseconds: latency))")
            }
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                hotkeyHints(titled: true)
                hotkeyHints(titled: false)
            }
        }
        .font(Theme.metaFont.monospacedDigit())
        .foregroundStyle(.secondary)
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
        HStack(spacing: 0) {
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
            HStack(spacing: 6) {
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
