import ListenerCore
import SwiftUI

/// One call's page: the summary Claude wrote, the transcript with the suggested answers
/// where they were asked for, and the answers on their own, under the call's title, its
/// figures and who spoke when.
struct CallDetailView: View {
    @Bindable var model: CallsModel
    let detail: CallDetail

    var body: some View {
        VStack(spacing: 0) {
            SectionBar {
                Chips(
                    options: [
                        .init(value: CallsModel.Tab.summary, title: "Summary"),
                        .init(value: .transcript, title: "Transcript"),
                        .init(value: .answers, title: "Answers", count: detail.answers.count),
                    ], selection: $model.tab, label: "Show"
                )
                .padding(.leading, 12)
                Spacer()
                switch model.tab {
                case .summary:
                    if detail.summary?.email != nil {
                        Button(action: model.copyEmail) {
                            Label("Copy follow-up email", systemImage: "envelope")
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                case .transcript:
                    Button(action: model.copyTranscript) {
                        Label("Copy transcript", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(detail.turns.isEmpty)
                case .answers:
                    EmptyView()
                }
                Button(action: model.revealInFinder) {
                    Image(systemName: "folder")
                }
                .buttonStyle(IconButtonStyle())
                .help("Show the call's files in Finder")
                .accessibilityLabel("Show in Finder")
                Menu {
                    if detail.summaryMarkdown != nil {
                        Button("Open summary.md", action: model.openSummaryFile)
                    }
                    if model.canWriteSummary {
                        Button(
                            detail.summary == nil ? "Write the Summary" : "Write the Summary Again",
                            action: model.writeSummary
                        )
                        .disabled(model.isWritingSummary || detail.turns.isEmpty)
                    }
                    Button("Open Sessions Folder", action: model.openSessionsFolder)
                    Divider()
                    Button("Move to Bin…", action: model.delete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(IconButtonStyle())
                .fixedSize()
                .accessibilityLabel("More")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let message = model.message {
                        MessageBanner(text: message) { model.message = nil }
                            .padding(.bottom, 18)
                    }
                    CallHeading(detail: detail)
                    switch model.tab {
                    case .summary:
                        SummaryPage(model: model, detail: detail)
                    case .transcript:
                        TranscriptPage(detail: detail, query: model.query)
                    case .answers:
                        AnswersPage(model: model, detail: detail)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 18)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The call's title, with its type and when over it, and its figures and who spoke when
/// on a tile under it.
private struct CallHeading: View {
    let detail: CallDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kicker)
                .font(.geist(13))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.horizontal, 4)
            Text(CallText.title(detail.call))
                .heading(30)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 22) {
                Figures(detail: detail)
                if !detail.turns.isEmpty {
                    CallTimeline(detail: detail)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tile()
            .padding(.top, 20)
        }
    }

    /// "Work call · Today 14:05"
    private var kicker: String {
        [detail.call.callType, CallText.when(detail.call.startedAt)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The call's length, how long each side spoke, its turns and its cost, large.
private struct Figures: View {
    let detail: CallDetail

    var body: some View {
        let call = detail.call
        let me = detail.talkTime[.me] ?? 0
        let them = detail.talkTime[.them] ?? 0
        HStack(alignment: .top, spacing: 12) {
            if let duration = call.duration {
                Figure(value: DisplayFormat.clock(duration), label: "Length")
            }
            if me > 0 || them > 0 {
                Figure(value: DisplayFormat.clock(me), label: "You spoke")
                Figure(value: DisplayFormat.clock(them), label: "They spoke")
            }
            Figure(value: "\(call.turnCount)", label: call.turnCount == 1 ? "Turn" : "Turns")
            if let cost = call.cost {
                Figure(value: DisplayFormat.cost(cost.total), label: "Cost")
                    .help(
                        "Speech to text \(DisplayFormat.cost(cost.speechCost)), Claude \(DisplayFormat.cost(cost.modelCost))"
                    )
            }
        }
    }
}

private struct Figure: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .heading(22)
                .monospacedDigit()
            Text(label)
                .font(.geist(12.5))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Who spoke when, as one bar across the call: you in ink, them in grey, and a dot over
/// each moment an answer was asked for, named where there is room.
private struct CallTimeline: View {
    let detail: CallDetail

    var body: some View {
        let length = max(detail.call.duration ?? 0, detail.turns.map(\.end).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 9) {
            Canvas { context, size in
                draw(length: length, in: &context, size: size)
            }
            .frame(height: 30)
            HStack(spacing: 14) {
                Text("0:00")
                Spacer(minLength: 8)
                Key(color: Theme.ink, label: "You")
                Key(color: Theme.otherSpeaker, label: "Them")
                Spacer(minLength: 8)
                Text(DisplayFormat.clock(length))
            }
            .font(.geist(12))
            .monospacedDigit()
            .foregroundStyle(Theme.tertiaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel(length: length))
    }

    private func draw(length: Double, in context: inout GraphicsContext, size: CGSize) {
        let bar = CGRect(x: 0, y: size.height - 6, width: size.width, height: 6)
        let track = Path(roundedRect: bar, cornerRadius: 3)
        context.fill(track, with: .color(Theme.selection))
        var turns = context
        turns.clip(to: track)
        for turn in detail.turns {
            let start = turn.start / length * size.width
            let end = max(turn.end / length * size.width, start + 1.5)
            turns.fill(
                Path(CGRect(x: start, y: bar.minY, width: end - start, height: bar.height)),
                with: .color(turn.speaker == .me ? Theme.ink : Theme.otherSpeaker))
        }
        var labelEnd = -CGFloat.infinity
        for answer in detail.answers.sorted(by: { $0.askedAt < $1.askedAt }) {
            let x = min(max(answer.askedAt / length * size.width, 3.5), size.width - 3.5)
            context.fill(
                Path(ellipseIn: CGRect(x: x - 3.5, y: 4.5, width: 7, height: 7)), with: .color(Theme.accent))
            let label = context.resolve(
                Text("\(answer.tier.title) answer, \(DisplayFormat.clock(answer.askedAt))")
                    .font(.geist(11.5, .medium))
                    .foregroundStyle(Theme.accentText))
            // Right of the dot where it fits, otherwise left of it, and never over the last.
            let width = label.measure(in: CGSize(width: 400, height: 20)).width
            if x + 8 + width <= size.width, x + 8 > labelEnd + 12 {
                context.draw(label, at: CGPoint(x: x + 8, y: 8), anchor: .leading)
                labelEnd = x + 8 + width
            } else if x - 8 - width > max(labelEnd + 12, 0) {
                context.draw(label, at: CGPoint(x: x - 8, y: 8), anchor: .trailing)
                labelEnd = x
            }
        }
    }

    private func spokenLabel(length: Double) -> String {
        let answers = detail.answers.map { "\($0.tier.noun) at \(DisplayFormat.clock($0.askedAt))" }
        return (["Who spoke when, over \(DisplayFormat.clock(length))"] + answers).joined(separator: "; ")
    }
}

private struct Key: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
        }
    }
}

// MARK: Summary

private struct SummaryPage: View {
    let model: CallsModel
    let detail: CallDetail

    var body: some View {
        if let summary = detail.summary {
            VStack(alignment: .leading, spacing: 0) {
                if !summary.summary.isEmpty {
                    SectionHeading("Summary")
                        .padding(.top, 32)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(summary.summary.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text("\(index + 1)")
                                    .font(.geist(13, .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.tertiaryText)
                                    .frame(width: 24, alignment: .leading)
                                MarkdownText(line)
                            }
                        }
                    }
                    .padding(20)
                    .tile()
                }
                let mine = summary.actionItems.filter(\.isMine)
                let others = summary.actionItems.filter { !$0.isMine }
                if !mine.isEmpty {
                    ActionItemList(title: "Your action items", items: mine) { model.setDone($0, for: $1) }
                        .padding(.top, 32)
                }
                if !others.isEmpty {
                    ActionItemList(title: "Waiting on others", items: others) { model.setDone($0, for: $1) }
                        .padding(.top, 32)
                }
                if !summary.decisions.isEmpty || !summary.openQuestions.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        if !summary.decisions.isEmpty {
                            Lines(title: "Decided", lines: summary.decisions)
                        }
                        if !summary.openQuestions.isEmpty {
                            Lines(title: "Still open", lines: summary.openQuestions)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 32)
                }
                if let email = summary.email {
                    EmailSection(email: email, copy: model.copyEmail)
                        .padding(.top, 32)
                }
                ForEach(Array(summary.other.enumerated()), id: \.offset) { _, section in
                    SectionHeading(section.heading)
                        .padding(.top, 32)
                    MarkdownText(section.text)
                        .padding(20)
                        .tile()
                }
                if summary.cutShort {
                    Text("The summary reached its length limit, so its end is missing.")
                        .font(.geist(12.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.horizontal, 4)
                        .padding(.top, 16)
                }
            }
        } else {
            NoSummary(model: model, detail: detail)
                .padding(.top, 32)
        }
    }
}

private struct NoSummary: View {
    let model: CallsModel
    let detail: CallDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .heading(18)
                .accessibilityAddTraits(.isHeader)
            Text(reason)
                .font(.geist(15))
                .lineSpacing(5)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if model.canWriteSummary && !detail.turns.isEmpty && !detail.call.summaryDue {
                Button(action: model.writeSummary) {
                    Label(model.isWritingSummary ? "Writing…" : "Write the Summary", systemImage: "sparkles")
                }
                .buttonStyle(PillButtonStyle(kind: .ink))
                .disabled(model.isWritingSummary)
                .padding(.top, 8)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile()
    }

    private var title: String {
        detail.call.summaryDue || model.isWritingSummary ? "Writing the summary…" : "No summary"
    }

    private var reason: String {
        if detail.call.summaryDue || model.isWritingSummary {
            return "Claude is writing the notes for this call. They show here when they are ready."
        }
        if detail.turns.isEmpty {
            return "Nothing was said on this call, so there is nothing to summarise."
        }
        if !model.canWriteSummary {
            return "Summaries need an Anthropic API key. The transcript and answers are on the other tabs."
        }
        return "Claude can write one now from the transcript: what was decided, the action items and a follow-up email."
    }
}

/// A line of the summary with its **bold** and *italics*, selectable for copying.
private struct MarkdownText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(
            (try? AttributedString(
                markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
        )
        .font(.geist(15))
        .lineSpacing(5)
        .foregroundStyle(Theme.proseText)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The user's action items, or everyone else's, on a tile, with how many are ticked.
private struct ActionItemList: View {
    let title: String
    let items: [CallSummary.ActionItem]
    let setDone: (Bool, CallSummary.ActionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: title) {
                Text("\(items.filter(\.done).count) of \(items.count) done")
            }
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        Hairline()
                            .padding(.leading, 29)
                    }
                    ActionItemRow(item: item) { setDone($0, item) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
            .tile()
        }
    }
}

private struct ActionItemRow: View {
    let item: CallSummary.ActionItem
    let setDone: (Bool) -> Void

    var body: some View {
        Button {
            setDone(!item.done)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Checkbox(isOn: item.done)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3.5 }
                (owner + body(ownerName == nil ? capitalisingFirstLetter(item.text) : item.text))
                    .font(.geist(15))
                    .lineSpacing(4)
                    .foregroundStyle(item.done ? Theme.tertiaryText : Theme.text)
                    .strikethrough(item.done, color: Theme.tertiaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([ownerName, item.text].compactMap { $0 }.joined(separator: ": "))
        .accessibilityValue(item.done ? "Done" : "Not done")
        .accessibilityAddTraits(.isToggle)
    }

    /// Who it is for, with the user as "You", unless it is the user's alone: those are
    /// listed under their own heading.
    private var ownerName: String? {
        guard let owner = item.owner, owner != "Me" else {
            return nil
        }
        return owner.replacingOccurrences(of: #"\bMe\b"#, with: "You", options: .regularExpression)
    }

    private var owner: Text {
        guard let ownerName else {
            return Text("")
        }
        let tint = item.done ? Theme.tertiaryText : item.isMine ? Theme.accentText : Theme.amber
        return Text("\(ownerName)  ").font(.geist(13.5, .semibold)).foregroundColor(tint)
    }

    /// Notes write "**Me**: send it", which reads as "send it" once the owner is not shown.
    private func capitalisingFirstLetter(_ text: String) -> String {
        guard let first = text.firstIndex(where: { !"*_`".contains($0) }), text[first].isLowercase else {
            return text
        }
        return text.replacingCharacters(in: first...first, with: text[first].uppercased())
    }

    private func body(_ text: String) -> Text {
        Text(
            (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text))
    }
}

/// What was decided, or what is still open, on a tile of its own.
private struct Lines: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.geist(15, .semibold))
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                MarkdownText(line)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile()
    }
}

private struct EmailSection: View {
    let email: CallSummary.Email
    let copy: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "Follow-up email") {
                Button {
                    copy()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(PillButtonStyle(small: true))
            }
            VStack(alignment: .leading, spacing: 10) {
                if let subject = email.subject {
                    Text(subject)
                        .font(.geist(15, .semibold))
                        .textSelection(.enabled)
                }
                Text(email.body)
                    .font(.geist(15))
                    .lineSpacing(5)
                    .foregroundStyle(Theme.proseText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tile()
        }
    }
}

// MARK: Transcript

/// Every turn, with each suggested answer placed where it was asked for.
private struct TranscriptPage: View {
    let detail: CallDetail
    let query: String

    private enum Item: Identifiable {
        case turn(Turn)
        case answer(AnswerRecord)

        var id: String {
            switch self {
            case .turn(let turn): "t\(turn.id)"
            case .answer(let answer): "a\(answer.id)"
            }
        }
    }

    var body: some View {
        if detail.turns.isEmpty {
            Text("Nothing was transcribed on this call.")
                .font(.geist(15))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 4)
                .padding(.top, 32)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    switch item {
                    case .turn(let turn):
                        TranscriptLine(turn: turn, words: words)
                    case .answer(let answer):
                        InlineAnswer(answer: answer)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .tile()
            .padding(.top, 32)
        }
    }

    private var items: [Item] {
        var items: [Item] = []
        var answers = detail.answers.sorted { $0.askedAt < $1.askedAt }[...]
        for turn in detail.turns {
            while let next = answers.first, next.askedAt < turn.start {
                items.append(.answer(next))
                answers = answers.dropFirst()
            }
            items.append(.turn(turn))
        }
        items += answers.map(Item.answer)
        return items
    }

    private var words: [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

private struct TranscriptLine: View {
    let turn: Turn
    let words: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(DisplayFormat.clock(turn.start))
                .font(.geist(12))
                .monospacedDigit()
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(turn.speaker.spokenName)
                    .font(.geist(12, .semibold))
                    .foregroundStyle(turn.speaker.tint)
                Text(highlighted)
                    .font(.geist(14))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.proseText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
    }

    private var highlighted: AttributedString {
        var text = AttributedString(turn.text)
        for word in words where !word.isEmpty {
            var searchRange = text.startIndex..<text.endIndex
            while let found = text[searchRange].range(
                of: word, options: [.caseInsensitive, .diacriticInsensitive])
            {
                text[found].backgroundColor = Theme.amber.opacity(0.25)
                text[found].foregroundColor = Theme.text
                searchRange = found.upperBound..<text.endIndex
            }
        }
        return text
    }
}

private struct InlineAnswer: View {
    let answer: AnswerRecord

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(DisplayFormat.clock(answer.askedAt))
                .font(.geist(12))
                .monospacedDigit()
                .foregroundStyle(Theme.accentText)
                .frame(width: 40, alignment: .leading)
                .padding(.top, 13)
            AnswerSummaryCard(answer: answer, compact: true)
        }
        .padding(.vertical, 8)
    }
}

// MARK: Answers

private struct AnswersPage: View {
    let model: CallsModel
    let detail: CallDetail

    var body: some View {
        if detail.answers.isEmpty {
            Text("No answers were asked for on this call.")
                .font(.geist(15))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 4)
                .padding(.top, 32)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(detail.answers, id: \.id) { answer in
                    AnswerSummaryCard(answer: answer, compact: false) { model.copyAnswer(answer) }
                }
            }
            .padding(.top, 32)
        }
    }
}

/// A suggested answer as it was given: its kind, model, speed and cost, then the words,
/// with notes meant only for the user set apart.
private struct AnswerSummaryCard: View {
    let answer: AnswerRecord
    let compact: Bool
    var copy: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                TierBadge(tier: answer.tier)
                Text(meta)
                    .font(.geist(12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let copy {
                    Button(action: copy) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help("Copy the \(answer.tier.noun), without the notes for you")
                    .accessibilityLabel("Copy the \(answer.tier.noun)")
                }
            }
            if let error = answer.error {
                Text(error)
                    .font(.geist(12.5))
                    .foregroundStyle(Theme.danger)
            }
            ForEach(AnswerMarkup(answer.text).blocks) { block in
                AnswerLine(block: block, size: compact ? 14 : 15)
            }
        }
        .padding(.leading, compact ? 16 : 20)
        .padding(.trailing, compact ? 10 : 14)
        .padding(.vertical, compact ? 14 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            compact ? Theme.accentTint : Theme.tile,
            in: RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous))
    }

    private var meta: String {
        var parts = [DisplayFormat.modelName(answer.model)]
        if let first = answer.latency.hotkeyToFirstToken {
            parts.append(DisplayFormat.latency(milliseconds: first))
        }
        if answer.cost > 0 {
            parts.append(DisplayFormat.preciseCost(answer.cost))
        }
        if !compact {
            parts.insert("at \(DisplayFormat.clock(answer.askedAt))", at: 0)
        }
        return parts.joined(separator: " · ")
    }
}

private struct AnswerLine: View {
    let block: AnswerBlock
    let size: CGFloat

    var body: some View {
        switch block.kind {
        case .note:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel("For you", tint: Theme.amber)
                Text(block.text)
                    .font(.geist(12.5))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.proseText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .panel(Theme.noteFill, radius: 8, stroke: Theme.noteBorder)
        case .bullet(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .foregroundStyle(Theme.tertiaryText)
                words
            }
            .font(.geist(size))
        case .paragraph:
            words
        }
    }

    private var words: some View {
        Text(block.text)
            .font(.geist(size))
            .lineSpacing(4)
            .foregroundStyle(Theme.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
