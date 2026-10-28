import ListenerCore
import SwiftUI

/// One call's page: the summary Claude wrote, the transcript with the suggested answers
/// where they were asked for, and the answers on their own.
struct CallDetailView: View {
    @Bindable var model: CallsModel
    let detail: CallDetail

    var body: some View {
        VStack(spacing: 0) {
            SectionBar {
                SegmentedControl(
                    options: [
                        .init(value: CallsModel.Tab.summary, title: "Summary"),
                        .init(value: .transcript, title: "Transcript"),
                        .init(value: .answers, title: "Answers", count: detail.answers.count),
                    ], selection: $model.tab, label: "Show")
                Spacer()
                switch model.tab {
                case .summary:
                    if detail.summary?.email != nil {
                        Button(action: model.copyEmail) {
                            Label("Copy follow-up email", systemImage: "envelope")
                        }
                        .buttonStyle(SoftButtonStyle())
                    }
                case .transcript:
                    Button(action: model.copyTranscript) {
                        Label("Copy transcript", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(SoftButtonStyle())
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
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The call's title, with its type and when over it, and its figures in a strip under
/// it like the ones on the Insights page.
private struct CallHeading: View {
    let detail: CallDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(kicker)
            Text(CallText.title(detail.call))
                .font(.geist(22, .semibold))
                .tracking(-0.45)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            CallFigures(detail: detail)
                .padding(.top, 18)
        }
    }

    /// "Work call · Yesterday 14:05", set in capitals over the title.
    private var kicker: String {
        [detail.call.callType, CallText.when(detail.call.startedAt)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// How long the call was, who spoke for how long, its turns and what it cost.
private struct CallFigures: View {
    let detail: CallDetail

    var body: some View {
        let call = detail.call
        HStack(spacing: 0) {
            if let duration = call.duration {
                Figure(value: DisplayFormat.clock(duration), label: "duration")
                VerticalHairline()
            }
            ForEach(Speaker.allCases, id: \.self) { speaker in
                if let seconds = detail.talkTime[speaker], seconds > 0 {
                    Figure(
                        value: DisplayFormat.clock(seconds), label: speaker == .me ? "you spoke" : "they spoke",
                        tint: speaker.tint)
                    VerticalHairline()
                }
            }
            Figure(value: call.turnCount.formatted(), label: call.turnCount == 1 ? "turn" : "turns")
            if let cost = call.cost {
                VerticalHairline()
                Figure(value: DisplayFormat.cost(cost.total), label: "cost")
                    .help(
                        "Speech to text \(DisplayFormat.cost(cost.speechCost)), Claude \(DisplayFormat.cost(cost.modelCost))"
                    )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .card()
    }
}

private struct Figure: View {
    let value: String
    let label: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.geistMono(17, .medium))
                .tracking(-0.3)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 6) {
                if let tint {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint)
                        .frame(width: 7, height: 7)
                }
                Text(label)
                    .lineLimit(1)
            }
            .font(.geist(11.5))
            .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Summary

private struct SummaryPage: View {
    let model: CallsModel
    let detail: CallDetail

    var body: some View {
        if let summary = detail.summary {
            VStack(alignment: .leading, spacing: 14) {
                if !summary.summary.isEmpty {
                    TitledCard("Summary") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(summary.summary.enumerated()), id: \.offset) { _, line in
                                Bullet(text: line)
                            }
                        }
                    }
                }
                let mine = summary.actionItems.filter(\.isMine)
                let others = summary.actionItems.filter { !$0.isMine }
                if !mine.isEmpty {
                    ActionItemList(title: "Your action items", items: mine) { model.setDone($0, for: $1) }
                }
                if !others.isEmpty {
                    ActionItemList(title: "Waiting on others", items: others) { model.setDone($0, for: $1) }
                }
                if !summary.decisions.isEmpty || !summary.openQuestions.isEmpty {
                    HStack(alignment: .top, spacing: 14) {
                        if !summary.decisions.isEmpty {
                            ListCard(title: "Decided", lines: summary.decisions)
                        }
                        if !summary.openQuestions.isEmpty {
                            ListCard(title: "Still open", lines: summary.openQuestions)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let email = summary.email {
                    EmailCard(email: email, copy: model.copyEmail)
                }
                ForEach(Array(summary.other.enumerated()), id: \.offset) { _, section in
                    TitledCard(section.heading) {
                        MarkdownText(section.text)
                    }
                }
                if summary.cutShort {
                    Text("The summary reached its length limit, so its end is missing.")
                        .font(.geistItalic(12))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.top, 14)
        } else {
            NoSummary(model: model, detail: detail)
                .padding(.top, 14)
        }
    }
}

private struct NoSummary: View {
    let model: CallsModel
    let detail: CallDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.geist(14, .semibold))
            Text(reason)
                .font(.geist(12.5))
                .lineSpacing(2)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if model.canWriteSummary && !detail.turns.isEmpty && !detail.call.summaryDue {
                Button(action: model.writeSummary) {
                    Label(model.isWritingSummary ? "Writing…" : "Write the Summary", systemImage: "sparkles")
                }
                .buttonStyle(FilledButtonStyle())
                .disabled(model.isWritingSummary)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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

private struct Bullet: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(Theme.tertiaryText.opacity(0.6))
                .frame(width: 4, height: 4)
                .offset(y: -3.5)
            MarkdownText(text)
        }
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
        .font(.geist(13.5))
        .lineSpacing(4)
        .foregroundStyle(Theme.proseText)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The user's action items, or everyone else's, with how many are ticked.
private struct ActionItemList: View {
    let title: String
    let items: [CallSummary.ActionItem]
    let setDone: (Bool, CallSummary.ActionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: title) {
                Text("\(items.filter(\.done).count) of \(items.count) done")
                    .font(.geistMono(11))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Hairline()
                        .padding(.leading, 44)
                        .padding(.trailing, 16)
                }
                ActionItemRow(item: item) { setDone($0, item) }
            }
        }
        .padding(.bottom, 4)
        .card()
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
                VStack(alignment: .leading, spacing: 0) {
                    (owner + body(ownerName == nil ? capitalisingFirstLetter(item.text) : item.text))
                        .font(.geist(13.5))
                        .lineSpacing(3)
                        .foregroundStyle(item.done ? Theme.tertiaryText : Theme.proseText)
                        .strikethrough(item.done, color: Theme.tertiaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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
        return Text("\(ownerName)  ").font(.geist(12, .semibold)).foregroundColor(tint)
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

private struct ListCard: View {
    let title: String
    let lines: [String]

    var body: some View {
        TitledCard(title) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Bullet(text: line)
                }
            }
        }
    }
}

private struct EmailCard: View {
    let email: CallSummary.Email
    let copy: () -> Void
    @State private var copied = false

    var body: some View {
        TitledCard(title: "Follow-up email") {
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
            .buttonStyle(SoftButtonStyle(small: true))
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if let subject = email.subject {
                    Text(subject)
                        .font(.geist(13.5, .semibold))
                        .textSelection(.enabled)
                }
                Text(email.body)
                    .font(.geist(13.5))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.proseText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                .font(.geist(13))
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 20)
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
            .padding(.top, 12)
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
                .font(.geistMono(11))
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
                .font(.geistMono(11))
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
                .font(.geist(13))
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 20)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(detail.answers, id: \.id) { answer in
                    AnswerSummaryCard(answer: answer, compact: false) { model.copyAnswer(answer) }
                }
            }
            .padding(.top, 14)
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
                    .font(.geistMono(11))
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
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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
