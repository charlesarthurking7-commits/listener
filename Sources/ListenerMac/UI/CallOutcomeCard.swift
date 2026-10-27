import ListenerCore
import SwiftUI

/// After Stop: progress while the call is saved, then the saved call with its length,
/// turns and cost, a way to its summary once it is written, and New Call to go back to
/// the start screen. A new call can start while the summary is still being written.
struct CallOutcomeCard: View {
    let model: CallModel
    /// Opens the call's page in the main window.
    let showMain: @MainActor (URL?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                icon
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.outcome != nil ? "Call saved" : "Saving the call…")
                        .font(.geist(14.5, .semibold))
                        .tracking(-0.15)
                    Text(model.activeCall.map { $0.callType.isEmpty ? "Call" : $0.callType } ?? "Call")
                        .font(.geist(12))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 4)
                if model.outcome != nil {
                    Button(action: model.newCall) {
                        Label("New Call", systemImage: "plus")
                    }
                    .buttonStyle(SoftButtonStyle(small: true))
                    .help("Back to the start screen to set up the next call")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 12)
            Hairline()
            HStack(spacing: 0) {
                Stat(label: "Length", value: duration.map(DisplayFormat.clock) ?? "-")
                VerticalHairline()
                Stat(label: "Turns", value: "\(turns)")
                VerticalHairline()
                Stat(label: "Cost", value: DisplayFormat.cost(cost))
            }
            .fixedSize(horizontal: false, vertical: true)
            if let outcome = model.outcome, let directory = outcome.directory {
                Hairline()
                HStack(spacing: 8) {
                    if outcome.summaryFile != nil {
                        Button {
                            showMain(URL(fileURLWithPath: directory))
                        } label: {
                            Label("Open Summary", systemImage: "doc.text")
                        }
                        .buttonStyle(FilledButtonStyle(small: true))
                        .help("The summary, transcript and answers, in Listener")
                    } else if outcome.writingSummary {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Writing the summary…")
                                .font(.geist(12))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        Button {
                            showMain(URL(fileURLWithPath: directory))
                        } label: {
                            Label("Open Call", systemImage: "waveform")
                        }
                        .buttonStyle(SoftButtonStyle(small: true))
                    }
                    Button {
                        model.perform(.revealInFinder(path: directory))
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(SoftButtonStyle(small: true))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .card()
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var icon: some View {
        if model.outcome != nil {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.ready)
                .frame(width: 30, height: 30)
                .background(Theme.ready.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var duration: Double? { model.outcome?.duration }
    private var turns: Int { model.outcome?.turnCount ?? model.settledRows.count }
    private var cost: Double { model.outcome?.cost ?? model.cost.total }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(label)
            Text(value)
                .font(.geistMono(14, .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
