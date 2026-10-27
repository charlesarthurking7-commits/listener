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
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 26)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The call's title and the facts about it.
private struct CallHeading: View {
    let detail: CallDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let type = detail.call.callType {
                    MetaChip(text: type)
                }
                MetaChip(text: CallText.when(detail.call.startedAt), mono: false)
                if let duration = detail.call.duration {
                    MetaChip(text: DisplayFormat.clock(duration), mono: true)
                }
                MetaChip(text: detail.call.turnCount == 1 ? "1 turn" : "\(detail.call.turnCount) turns")
                if let cost = detail.call.cost {
                    MetaChip(text: DisplayFormat.cost(cost.total), mono: true)
                        .help(
                            "Speech to text \(DisplayFormat.cost(cost.speechCost)), Claude \(DisplayFormat.cost(cost.modelCost))"
                        )
                }
            }
            Text(CallText.title(detail.call))
                .font(.geist(21, .semibold))
                .tracking(-0.4)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            if detail.talkTime.values.contains(where: { $0 > 0 }) {
                HStack(spacing: 14) {
                    ForEach(Speaker.allCases, id: \.self) { speaker in
                        if let seconds = detail.talkTime[speaker], seconds > 0 {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(speaker.tint)
                                    .frame(width: 7, height: 7)
                                Text("\(speaker.spokenName) spoke for \(DisplayFormat.clock(seconds))")
                            }
                        }
                    }
                }
                .font(.geist(12))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.top, 9)
            }
        }
    }
}

private struct MetaChip: View {
    let text: String
    var mono = false

    var body: some View {
        Text(text)
            .font(mono ? .geistMono(11.5) : .geist(11.5))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .panel(Theme.surface, radius: 6)
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
                    SectionLabel("Summary")
                        .padding(.top, 28)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(summary.summary.enumerated()), id: \.offset) { _, line in
                            Bullet(text: line)
                        }
                    }
                    .padding(.top, 12)
                }
                let mine = summary.actionItems.filter(\.isMine)
                let others = summary.actionItems.filter { !$0.isMine }
                if !mine.isEmpty {
                    ActionItemList(title: "Your action items", items: mine) { model.setDone($0, for: $1) }
                        .padding(.top, 28)
                }
                if !others.isEmpty {
                    ActionItemList(title: "Waiting on others", items: others) { model.setDone($0, for: $1) }
                        .padding(.top, mine.isEmpty ? 28 : 20)
                }
                if !summary.decisions.isEmpty || !summary.openQuestions.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        if !summary.decisions.isEmpty {
                            ListCard(title: "Decided", tint: Theme.tertiaryText, lines: summary.decisions)
                        }
                        if !summary.openQuestions.isEmpty {
                            ListCard(title: "Still open", tint: Theme.amber, lines: summary.openQuestions)
                        }
                    }
                    .padding(.top, 16)
                }
                if let email = summary.email {
                    EmailCard(email: email, copy: model.copyEmail)
                        .padding(.top, 16)
                }
                ForEach(Array(summary.other.enumerated()), id: \.offset) { _, section in
                    SectionLabel(section.heading)
                        .padding(.top, 28)
                    MarkdownText(section.text)
                        .padding(.top, 10)
                }
                if summary.cutShort {
                    Text("The summary reached its length limit, so its end is missing.")
                        .font(.geistItalic(12))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.top, 16)
                }
            }
        } else {
            NoSummary(model: model, detail: detail)
                .padding(.top, 28)
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
                .frame(width: 4.5, height: 4.5)
                .offset(y: -3)
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
        .font(.geist(14.5))
        .lineSpacing(5)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(title)
                Spacer()
                Text("\(items.filter(\.done).count) of \(items.count) done")
                    .font(.geistMono(11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        Hairline()
                    }
                    ActionItemRow(item: item) { setDone($0, item) }
                }
            }
            .card()
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
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(item.done ? Theme.accent : Theme.tertiaryText)
                    .offset(y: 1)
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
            .padding(.horizontal, 14)
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
    let tint: Color
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(title, tint: tint)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(
                    (try? AttributedString(
                        markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                        ?? AttributedString(line)
                )
                .font(.geist(13))
                .lineSpacing(3)
                .foregroundStyle(Theme.proseText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }
}

private struct EmailCard: View {
    let email: CallSummary.Email
    let copy: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Follow-up email")
                Spacer()
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
            }
            if let subject = email.subject {
                Text(subject)
                    .font(.geist(13.5, .semibold))
                    .textSelection(.enabled)
                    .padding(.top, 12)
            }
            Text(email.body)
                .font(.geist(13.5))
                .lineSpacing(4)
                .foregroundStyle(Theme.proseText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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
                .padding(.top, 28)
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
            .padding(.top, 18)
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
                .padding(.top, 28)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(detail.answers, id: \.id) { answer in
                    AnswerSummaryCard(answer: answer, compact: false) { model.copyAnswer(answer) }
                }
            }
            .padding(.top, 24)
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
        .padding(.leading, 13)
        .padding(.trailing, 10)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 10)
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
