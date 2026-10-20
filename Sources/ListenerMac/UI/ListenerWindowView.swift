import ListenerCore
import SwiftUI

/// The floating window, top to bottom: listening state and Start/Stop, banners, the
/// transcript, the answer card when there is one, and the cost/latency footer.
struct ListenerWindowView: View {
    let model: CallModel
    let hide: @MainActor () -> Void

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HeaderBar(model: model, hide: hide)
                NoticeStack(model: model)
                Divider()
                TranscriptView(model: model)
                    .frame(maxHeight: .infinity)
                if let card = model.state.answer {
                    AnswerCardView(
                        card: card,
                        maxTextHeight: max(proxy.size.height * 0.45, 120),
                        copy: model.copyAnswer,
                        dismiss: model.dismissAnswer
                    )
                    .id(card.id)
                    .padding(.horizontal, Theme.padding)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Divider()
                FooterBar(model: model)
            }
            .animation(.easeOut(duration: 0.18), value: model.state.answer?.id)
        }
        .frame(minWidth: 320, minHeight: 360)
        // The title bar is transparent and its buttons hidden, so the header uses
        // that space instead of sitting below an empty band.
        .ignoresSafeArea()
    }
}

private struct HeaderBar: View {
    let model: CallModel
    let hide: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ListeningIndicator(phase: model.state.phase, since: model.state.listeningSince)
            Spacer(minLength: 8)
            StartStopButton(model: model)
            Button(action: hide) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Hide the window. Show it again from the menu bar.")
        }
        .padding(.horizontal, Theme.padding)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(WindowDragArea())
    }
}

private struct ListeningIndicator: View {
    let phase: CallViewState.Phase
    let since: Date?

    var body: some View {
        switch phase {
        case .listening:
            HStack(spacing: 6) {
                PulsingDot()
                Text("Listening")
                    .font(.headline)
                    .foregroundStyle(.red)
                if let since {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(DisplayFormat.clock(context.date.timeIntervalSince(since)))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        case .starting:
            busy("Starting")
        case .stopping:
            busy("Saving the call")
        case .summarizing:
            busy("Writing the summary")
        case .idle, .finished:
            HStack(spacing: 6) {
                Circle()
                    .fill(.secondary)
                    .frame(width: 10, height: 10)
                    .frame(width: 20, height: 20)
                Text("Not listening")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func busy(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StartStopButton: View {
    let model: CallModel

    var body: some View {
        if model.state.canStop {
            Button(action: model.stop) {
                Label("Stop", systemImage: "stop.fill")
                    .frame(minWidth: 60)
            }
            .buttonStyle(FilledButtonStyle(tint: .red))
            .help(tooltip("Stop listening and save the call"))
        } else {
            Button(action: model.start) {
                Label("Start", systemImage: "mic.fill")
                    .frame(minWidth: 60)
            }
            .buttonStyle(FilledButtonStyle(tint: .accentColor))
            .disabled(!model.state.canStart)
            .help(tooltip("Start listening"))
        }
    }

    private func tooltip(_ text: String) -> String {
        guard let hotkey = model.activeHotkeys[.toggleListening] else {
            return text
        }
        return "\(text) (\(hotkey.displayString))"
    }
}

private struct NoticeStack: View {
    let model: CallModel

    var body: some View {
        let appNotices = model.appNotices.items
        let callNotices = model.state.notices
        if !appNotices.isEmpty || !callNotices.isEmpty {
            VStack(spacing: 6) {
                ForEach(appNotices) { notice in
                    NoticeBanner(notice: notice, perform: model.perform) { model.dismissAppNotice(notice) }
                }
                ForEach(callNotices) { notice in
                    NoticeBanner(notice: notice, perform: model.perform) { model.dismissNotice(notice) }
                }
            }
            .padding(.horizontal, Theme.padding)
            .padding(.bottom, 10)
        }
    }
}

private struct NoticeBanner: View {
    let notice: Notice
    let perform: @MainActor (NoticeAction) -> Void
    let dismiss: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(notice.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action = notice.action {
                Button(action.title) { perform(action) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct FooterBar: View {
    let model: CallModel

    var body: some View {
        HStack(spacing: 14) {
            Text("Cost \(DisplayFormat.cost(model.state.cost.total))")
                .help(costDetail)
            if let latency = model.state.lastLatencyMs {
                Text("First word \(DisplayFormat.latency(milliseconds: latency))")
                    .help("Time from the hotkey to the first word of the last answer")
            }
            Spacer(minLength: 8)
            hotkeyHint(.quickAnswer, "quick")
            hotkeyHint(.deepAnswer, "deep")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, Theme.padding)
        .padding(.vertical, 8)
        .background(WindowDragArea())
    }

    private var costDetail: String {
        let cost = model.state.cost
        return
            "Speech to text \(DisplayFormat.cost(cost.speechCost)), Claude \(DisplayFormat.cost(cost.modelCost))"
    }

    @ViewBuilder
    private func hotkeyHint(_ action: HotkeyAction, _ title: String) -> some View {
        if let hotkey = model.activeHotkeys[action] {
            HStack(spacing: 4) {
                Text(hotkey.displayString)
                    .fontWeight(.semibold)
                Text(title)
            }
            .help(action.title)
        }
    }
}
