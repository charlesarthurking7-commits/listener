import ListenerCore
import SwiftUI

/// The suggested answer: tier badge, model, first-token latency, copy and dismiss,
/// then the text as it streams in. Long answers scroll inside the card.
struct AnswerCardView: View {
    let card: AnswerCard
    let maxTextHeight: CGFloat
    let copy: @MainActor () -> Void
    let dismiss: @MainActor () -> Void

    @State private var copied = false
    @State private var textHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(12)
        .background(
            .background.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(card.tier.tint.opacity(0.5), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            TierBadge(tier: card.tier)
            Text(card.model)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let latency = card.firstTokenMs {
                Label(DisplayFormat.latency(milliseconds: latency), systemImage: "bolt.horizontal")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Time from the hotkey to the first word")
            }
            Button {
                copy()
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(card.text.isEmpty)
            .help("Copy the answer")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(card.isActive ? "Stop and dismiss" : "Dismiss")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch card.status {
        case .waiting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Thinking…")
                    .foregroundStyle(.secondary)
            }
        case .streaming, .finished:
            answerText
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if !card.text.isEmpty {
                    answerText
                }
            }
        }
    }

    /// Sized to the text up to `maxTextHeight`, then scrolls.
    private var answerText: some View {
        ScrollView {
            Text(card.text)
                .font(Theme.answerFont)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    textHeight = height
                }
        }
        .frame(height: min(max(textHeight, 20), maxTextHeight))
        .scrollIndicators(textHeight > maxTextHeight ? .automatic : .hidden)
    }
}
