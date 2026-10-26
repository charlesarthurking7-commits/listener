import ListenerCore
import SwiftUI

/// After Stop: progress while the call is saved, then the saved call with its length,
/// turns and cost, the summary once it is written, and New Call to go back to the
/// start screen. A new call can start while the summary is still being written.
struct CallOutcomeCard: View {
    let model: CallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                icon
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.2)
                    Text(details)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
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
            if let outcome = model.outcome, let directory = outcome.directory {
                HStack(spacing: 8) {
                    if let summary = outcome.summaryFile {
                        Button {
                            model.perform(.openFile(path: summary))
                        } label: {
                            Label("Open Summary", systemImage: "doc.text")
                        }
                        .buttonStyle(FilledButtonStyle(small: true))
                    } else if outcome.writingSummary {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Writing the summary…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Button {
                        model.perform(.revealInFinder(path: directory))
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(SoftButtonStyle(small: true))
                }
                .padding(.leading, 38)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 12)
        .panel()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var icon: some View {
        if model.outcome != nil {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.white, .green)
                .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var title: String {
        model.outcome != nil ? "Call saved" : "Saving the call…"
    }

    private var details: String {
        if let outcome = model.outcome {
            return outcome.details
        }
        let turns = model.settledRows.count
        return "\(turns == 1 ? "1 turn" : "\(turns) turns") · \(DisplayFormat.cost(model.cost.total))"
    }
}
