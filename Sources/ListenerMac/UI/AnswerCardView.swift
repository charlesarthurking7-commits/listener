import ListenerCore
import SwiftUI

/// The suggested answer: tier, model and time to the first word as quiet metadata, then
/// the words in a large size, with notes meant only for the user set apart. Long
/// answers scroll inside the card.
struct AnswerCardView: View {
    let model: CallModel
    let maxTextHeight: CGFloat

    private static let headerHeight: CGFloat = 24
    private static let spacing: CGFloat = 8
    private static let topPadding: CGFloat = 10
    private static let bottomPadding: CGFloat = 14
    /// Everything but the words: the header, the space under it and the padding.
    static let chromeHeight = headerHeight + spacing + topPadding + bottomPadding

    var body: some View {
        if let card = model.answer {
            VStack(alignment: .leading, spacing: Self.spacing) {
                AnswerHeader(card: card, model: model)
                    .frame(height: Self.headerHeight)
                AnswerContent(card: card, blocks: model.answerBlocks, maxTextHeight: maxTextHeight) {
                    model.ask(card.tier)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.top, Self.topPadding)
            .padding(.bottom, Self.bottomPadding)
            .panel(stroke: border(card).opacity(0.4), lineWidth: 1)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(card.tier == .recap ? "Recap so far" : "Suggested answer")
        }
    }

    private func border(_ card: AnswerCard) -> Color {
        if case .failed = card.status {
            return .red
        }
        return card.tier.tint
    }
}

private struct AnswerHeader: View {
    let card: AnswerCard
    let model: CallModel
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            TierBadge(tier: card.tier)
            HStack(spacing: 6) {
                Text(DisplayFormat.modelName(card.model))
                    .help(card.model)
                if let detail {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(detail)
                        .monospacedDigit()
                }
            }
            .font(Theme.metaFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            trailing
            Button(action: model.dismissAnswer) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .help(card.isActive ? "Stop and dismiss" : "Dismiss")
            .accessibilityLabel("\(card.isActive ? "Stop and dismiss" : "Dismiss") the \(card.tier.noun)")
        }
    }

    private var detail: String? {
        switch card.status {
        case .waiting:
            card.tier == .deep ? "Thinking…" : "Writing…"
        case .streaming, .finished:
            card.firstTokenMs.map { DisplayFormat.latency(milliseconds: $0) }
        case .failed:
            nil
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch card.status {
        case .waiting:
            EmptyView()
        case .failed:
            Button {
                model.ask(card.tier)
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SoftButtonStyle(small: true))
            .accessibilityLabel("Try the \(card.tier.noun) again")
        case .streaming, .finished:
            if copied {
                Label("Copied", systemImage: "checkmark")
                    .labelStyle(CompactLabelStyle(spacing: 4))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.trailing, 4)
                    .transition(.opacity)
                    .accessibilityLabel("Copied")
            } else {
                // Half an answer, or one that is only a note, is nothing to paste.
                Button(action: copy) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .disabled(card.status != .finished || !model.canCopyAnswer)
                .help("Copy the \(card.tier.noun), without the notes for you")
                .accessibilityLabel("Copy the \(card.tier.noun)")
            }
        }
    }

    private func copy() {
        guard model.copyAnswer() else {
            return
        }
        withAnimation(.easeOut(duration: 0.15)) {
            copied = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.25)) {
                copied = false
            }
        }
    }
}

private struct AnswerContent: View {
    let card: AnswerCard
    let blocks: [AnswerBlock]
    let maxTextHeight: CGFloat
    let retry: @MainActor () -> Void

    var body: some View {
        switch card.status {
        case .waiting:
            ShimmerBars()
                .frame(height: ShimmerView.height)
                .padding(.top, 6)
                .padding(.trailing, 8)
                .padding(.bottom, 4)
                .accessibilityLabel(card.tier == .deep ? "Thinking" : "Writing the \(card.tier.noun)")
        case .streaming, .finished:
            AnswerText(blocks: blocks, maxHeight: maxTextHeight)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.trailing, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("The answer failed: \(message)")
                if !blocks.isEmpty {
                    AnswerText(blocks: blocks, maxHeight: maxTextHeight)
                }
            }
        }
    }
}

/// Sized to the words up to `maxHeight`, then scrolls, with the last line fading out
/// and a chevron while there is more below. Each block is its own equatable view and
/// blocks only ever append, so a new word redraws the last block alone.
private struct AnswerText: View {
    let blocks: [AnswerBlock]
    let maxHeight: CGFloat
    @State private var height: CGFloat = 0
    @State private var moreBelow = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let chipIn = chipInBlock
                ForEach(blocks) { block in
                    if block.id == chipIn {
                        Text("If you want to chip in")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.4)
                            .textCase(.uppercase)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 10)
                            .accessibilityHidden(true)
                    }
                    AnswerBlockView(block: block, spacingAbove: block.id == chipIn ? 4 : spacing(above: block))
                        .equatable()
                }
            }
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                height = newHeight
            }
        }
        .frame(height: min(max(height, 24), maxHeight))
        .scrollIndicators(height > maxHeight ? .visible : .never)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 4
        } action: { _, more in
            moreBelow = more
        }
        .mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(
                    colors: [.black, .black.opacity(moreBelow ? 0 : 1)], startPoint: .top, endPoint: .bottom
                )
                .frame(height: 28)
            }
        }
        .overlay(alignment: .bottom) {
            if moreBelow {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                    .accessibilityLabel("More below")
            }
        }
    }

    /// When nothing was asked, the prompt has the answer open with a note saying so; any
    /// words after it are optional, and labelled so they don't read as a cue to speak.
    private var chipInBlock: Int? {
        guard let first = blocks.first, case .note = first.kind, first.text.hasPrefix("Nothing asked of you") else {
            return nil
        }
        return blocks.dropFirst().first { block in
            if case .note = block.kind {
                return false
            }
            return true
        }?.id
    }

    private func spacing(above block: AnswerBlock) -> CGFloat {
        guard block.id > 0, block.id <= blocks.count else {
            return 0
        }
        if case .bullet = block.kind, case .bullet = blocks[block.id - 1].kind {
            return 4
        }
        return 8
    }
}

private struct AnswerBlockView: View, Equatable {
    let block: AnswerBlock
    let spacingAbove: CGFloat

    var body: some View {
        content
            .padding(.top, spacingAbove)
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .paragraph:
            words
        case .bullet(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(Theme.answerFont)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 12)
                    .accessibilityHidden(true)
                words
            }
        case .note:
            NoteAside(text: block.text)
        }
    }

    private var words: some View {
        Text(Self.styled(block.spans))
            .font(Theme.answerFont)
            .tracking(-0.2)
            .lineSpacing(Theme.answerLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func styled(_ spans: [AnswerSpan]) -> AttributedString {
        var text = AttributedString()
        for span in spans {
            var run = AttributedString(span.text)
            switch span.style {
            case .plain:
                break
            case .bold:
                run[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .system(
                    size: Theme.answerSize, weight: .semibold)
            case .note:
                run[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .system(size: 15)
                run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Theme.noteLabel
            }
            text += run
        }
        return text
    }
}

/// A line in [square brackets]: for the user's eyes only, so it reads as an aside and
/// never as part of what to say.
private struct NoteAside: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("For you")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(Theme.noteLabel)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .background(Theme.noteFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Note for you, not to say: \(text)")
    }
}
