import ListenerCore
import SwiftUI

/// What the empty window shows before a call: each permission and setting that
/// matters, whether it is in place, and a one-click way to fix it.
struct SetupChecklist: View {
    let model: CallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Readiness.blocksStart(model.readiness) ? "Before your first call" : "Ready when you are")
                    .font(.title3.weight(.semibold))
                Text("Press Start when the call begins. Listener only listens while the red dot shows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.readiness) { item in
                    ReadinessRow(item: item, perform: model.perform)
                }
            }
            Button("Check Again", action: model.refreshReadiness)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReadinessRow: View {
    let item: ReadinessItem
    let perform: @MainActor (ReadinessFix) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout.weight(.semibold))
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = item.fix {
                    Button(title(for: fix)) { perform(fix) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch item.status {
        case .ready: "checkmark.circle.fill"
        case .willAsk: "hand.raised.circle.fill"
        case .limited: "exclamationmark.circle.fill"
        case .blocking: "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch item.status {
        case .ready: .green
        case .willAsk: .blue
        case .limited: .orange
        case .blocking: .red
        }
    }

    private func title(for fix: ReadinessFix) -> String {
        switch fix {
        case .openPrivacySettings: "Open System Settings"
        case .editSettings: "Open settings.json"
        case .runInTerminal(let command): "Copy \"\(command)\""
        }
    }
}
