import ListenerCore
import SwiftUI

/// What has to be in place before a call, each item with a one-click fix: on the Calls
/// page of the main window until nothing blocks a call and nothing is limited.
struct SetupChecklist: View {
    let model: CallModel

    var body: some View {
        let progress = Readiness.progress(model.readiness)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Set up Listener")
                    .font(.geist(19, .semibold))
                    .tracking(-0.3)
                    .accessibilityAddTraits(.isHeader)
                Text("A few things before your first call. Nothing is recorded until you press Start.")
                    .font(.geist(12.5))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
                ProgressSegments(progress: progress)
                    .padding(.top, 16)
                Text("\(progress.done) of \(progress.total) ready")
                    .font(.geistMono(11))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 7)
                VStack(spacing: 0) {
                    ForEach(Array(model.readiness.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Hairline()
                        }
                        ChecklistRow(item: item, perform: model.perform)
                    }
                }
                .card()
                .padding(.top, 14)
                HStack {
                    Text("Changed something?")
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer()
                    Button("Check Again", action: model.refreshReadiness)
                        .buttonStyle(LinkButtonStyle())
                        .accessibilityHint("Checks permissions, settings and the API key again")
                }
                .font(.geist(12))
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
                    .fill(index < progress.done ? AnyShapeStyle(Theme.ready) : AnyShapeStyle(Theme.selection))
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
            ReadinessIcon(status: item.status, size: 18)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.geist(13, .semibold))
                Text(item.detail)
                    .font(.geist(12))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.secondaryText)
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
                    .font(.geistMono(11))
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
            .frame(height: 32)
            .panel(Theme.well, radius: 8)
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
                    .foregroundStyle(.white, Theme.ready)
            case .willAsk:
                Image(systemName: "circle.dashed")
                    .foregroundStyle(Theme.tertiaryText)
            case .preparing:
                ProgressView()
                    .controlSize(.small)
            case .limited:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.white, Theme.amber)
            case .blocking:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.white, Theme.danger)
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

/// Centred placeholder for the body of the window while there is no transcript.
struct EmptyStateView: View {
    let title: String
    let message: String
    let model: CallModel
    var showsHearing = false

    var body: some View {
        VStack(spacing: 0) {
            Hero(title: title, message: message)
            if showsHearing, let hearing = model.hearing {
                HearingChips(hearing: hearing)
                    .padding(.top, 16)
            }
            ShortcutTable(model: model, actions: [.quickAnswer, .deepAnswer, .recap])
                .padding(.top, 22)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Hero: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "waveform")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 44, height: 44)
                .card(radius: 12)
                .padding(.bottom, 14)
                .accessibilityHidden(true)
            Text(title)
                .font(.geist(15, .semibold))
                .tracking(-0.2)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.geist(12.5))
                .lineSpacing(2)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
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
                Label(speaker.spokenName, systemImage: "waveform")
                    .labelStyle(CompactLabelStyle(spacing: 5))
                    .font(.geist(12, .semibold))
                    .foregroundStyle(active ? AnyShapeStyle(speaker.tint) : AnyShapeStyle(Theme.tertiaryText))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(
                        active ? AnyShapeStyle(speaker.tint.opacity(0.14)) : AnyShapeStyle(Theme.hover),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
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
                            .font(.geist(12))
                            .foregroundStyle(Theme.secondaryText)
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
        case .toggleWindow: "Show or hide"
        case .quickAnswer, .deepAnswer, .recap: action.title
        }
    }
}
