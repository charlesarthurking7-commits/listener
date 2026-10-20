import ListenerCore
import SwiftUI

/// What the window shows before a call. Until every permission and setting that
/// matters is in place, an onboarding checklist with a one-click fix for each item;
/// after that, a calm "ready" screen with the hotkeys and a compact status list.
struct SetupView: View {
    let model: CallModel

    var body: some View {
        if Readiness.needsAttention(model.readiness) {
            SetupChecklist(model: model)
        } else {
            ReadyView(model: model)
        }
    }
}

private struct SetupChecklist: View {
    let model: CallModel

    var body: some View {
        let progress = Readiness.progress(model.readiness)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Set up Listener")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.3)
                    .accessibilityAddTraits(.isHeader)
                Text("A few things before your first call. Nothing is recorded until you press Start.")
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                ProgressSegments(progress: progress)
                    .padding(.top, 14)
                Text("\(progress.done) of \(progress.total) ready")
                    .font(Theme.metaFont)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
                VStack(spacing: 0) {
                    ForEach(Array(model.readiness.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Hairline()
                        }
                        ChecklistRow(item: item, perform: model.perform)
                    }
                }
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
                }
                .padding(.top, 14)
                HStack {
                    Text("Changed something?")
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Check Again", action: model.refreshReadiness)
                        .buttonStyle(LinkButtonStyle())
                        .accessibilityHint("Checks permissions, settings and the API key again")
                }
                .font(.system(size: 12))
                .padding(.top, 14)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 20)
            .padding(.bottom, Theme.gutter)
        }
        .scrollIndicators(.automatic)
    }
}

private struct ProgressSegments: View {
    let progress: ReadinessProgress

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<progress.total, id: \.self) { index in
                Capsule()
                    .fill(index < progress.done ? AnyShapeStyle(.green) : AnyShapeStyle(Theme.strongFill))
                    .frame(height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup progress")
        .accessibilityValue("\(progress.done) of \(progress.total) ready")
    }
}

private struct ChecklistRow: View {
    let item: ReadinessItem
    let perform: @MainActor (ReadinessFix) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ReadinessIcon(status: item.status, size: 20)
                .frame(width: 22, height: 22)
                .padding(.top, -2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(item.detail)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = item.fix {
                    FixControl(fix: fix, status: item.status, perform: perform)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title): \(ReadinessIcon.statusName(item.status))")
    }
}

/// The way to fix an item. A command to run is shown in full with a Copy button, so it
/// is clear what will be pasted into Terminal.
private struct FixControl: View {
    let fix: ReadinessFix
    let status: ReadinessItem.Status
    let perform: @MainActor (ReadinessFix) -> Void

    var body: some View {
        switch fix {
        case .runInTerminal(let command):
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    perform(fix)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(SoftButtonStyle(small: true))
                .accessibilityLabel("Copy the command \(command)")
            }
            .padding(.leading, 10)
            .padding(.trailing, 2)
            .frame(height: 28)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
            }
            .padding(.top, 8)
        case .openPrivacySettings, .editSettings:
            if status == .blocking {
                Button(title) { perform(fix) }
                    .buttonStyle(FilledButtonStyle(small: true))
                    .padding(.top, 8)
            } else if status == .limited {
                Button(title) { perform(fix) }
                    .buttonStyle(SoftButtonStyle(small: true))
                    .padding(.top, 8)
            } else {
                Button(title) { perform(fix) }
                    .buttonStyle(LinkButtonStyle())
                    .padding(.top, 6)
            }
        }
    }

    private var title: String {
        switch fix {
        case .openPrivacySettings: "Open System Settings"
        case .editSettings: "Open settings.json"
        case .runInTerminal: "Copy"
        }
    }
}

struct ReadinessIcon: View {
    let status: ReadinessItem.Status
    let size: CGFloat

    var body: some View {
        Group {
            switch status {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, .green)
            case .willAsk:
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
            case .preparing:
                ProgressView()
                    .controlSize(.small)
            case .limited:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.white, .orange)
            case .blocking:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.white, .red)
            }
        }
        .font(.system(size: size))
        .accessibilityHidden(true)
    }

    static func statusName(_ status: ReadinessItem.Status) -> String {
        switch status {
        case .ready: "ready"
        case .willAsk: "macOS will ask when you press Start"
        case .preparing: "getting ready"
        case .limited: "works with limits"
        case .blocking: "needs fixing before a call"
        }
    }
}

private struct ReadyView: View {
    let model: CallModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            Hero(
                symbol: "waveform", tint: .accentColor, title: "Ready when you are",
                message: "Press Start when the call begins.\nNothing is recorded until then.")
            ShortcutTable(model: model, actions: [.toggleListening, .quickAnswer, .deepAnswer])
                .padding(.top, 22)
            Spacer(minLength: 16)
            VStack(spacing: 0) {
                ForEach(Array(model.readiness.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Hairline()
                    }
                    HStack(spacing: 8) {
                        ReadinessIcon(status: item.status, size: 14)
                            .frame(width: 16)
                        Text(item.title)
                            .font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 8)
                        Text(item.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .help(item.detail)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.title): \(item.summary)")
                }
            }
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
            }
            .padding(Theme.gutter)
        }
    }
}

/// Centred placeholder for the body of the window while there is no transcript.
struct EmptyStateView: View {
    let title: String
    let message: String
    let model: CallModel
    var showsHearing = false

    var body: some View {
        VStack(spacing: 0) {
            Hero(symbol: "waveform", tint: Color.secondary.opacity(0.6), title: title, message: message)
            if showsHearing, let hearing = model.hearing {
                HearingChips(hearing: hearing)
                    .padding(.top, 16)
            }
            ShortcutTable(model: model, actions: [.quickAnswer, .deepAnswer])
                .padding(.top, 22)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Hero: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(tint)
                .frame(height: 40)
                .padding(.bottom, 14)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.3)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }
}

/// Which channels hear speech right now, so a silent "Them" shows before anyone
/// wonders why the transcript is empty.
private struct HearingChips: View {
    let hearing: Set<Speaker>

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Speaker.allCases, id: \.self) { speaker in
                let active = hearing.contains(speaker)
                Label(speaker.rawValue, systemImage: "waveform")
                    .labelStyle(CompactLabelStyle(spacing: 5))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? AnyShapeStyle(speaker.tint) : AnyShapeStyle(.tertiary))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(
                        active ? AnyShapeStyle(speaker.tint.opacity(0.14)) : AnyShapeStyle(Theme.fill), in: Capsule()
                    )
                    .accessibilityLabel("\(speaker.spokenName): \(active ? "hearing speech" : "quiet")")
            }
        }
    }
}

private struct ShortcutTable: View {
    let model: CallModel
    let actions: [HotkeyAction]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            ForEach(actions, id: \.self) { action in
                if let hotkey = model.activeHotkeys[action] {
                    GridRow {
                        Text(label(action))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        HotkeyKeycaps(hotkey: hotkey, large: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(label(action)): \(hotkey.spokenName)")
                }
            }
        }
    }

    private func label(_ action: HotkeyAction) -> String {
        switch action {
        case .toggleListening: "Start or stop"
        case .quickAnswer: "Quick answer"
        case .deepAnswer: "Deep answer"
        }
    }
}
