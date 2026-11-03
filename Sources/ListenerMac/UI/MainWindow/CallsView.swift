import ListenerCore
import SwiftUI

/// Saved calls on the left, newest first and grouped by day, with a search across
/// everything said; the picked call on the right.
struct CallsView: View {
    let model: CallsModel

    var body: some View {
        HStack(spacing: 0) {
            CallList(model: model)
                .frame(width: 340)
            if let live = model.liveCallID, model.selection == live {
                LiveCallView(model: model)
            } else if let detail = model.detail {
                CallDetailView(model: model, detail: detail)
                    .id(detail.call.id)
            } else {
                NoCallView(model: model)
            }
        }
    }
}

private struct CallList: View {
    @Bindable var model: CallsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Calls", inset: 24) {
                Text(retention)
                    .font(.geist(12))
                    .foregroundStyle(Theme.tertiaryText)
                    .help("Keep calls for, in Settings under Storage and privacy: older calls are deleted at launch")
            }
            SearchField(prompt: "Search everything that was said", text: $model.query)
                .padding(.horizontal, 16)
            if model.callTypes.count > 1 {
                ScrollView(.horizontal) {
                    Chips(
                        options: [.init(value: nil, title: "All")]
                            + model.callTypes.map { .init(value: $0, title: $0) },
                        selection: $model.typeFilter, label: "Call type")
                }
                .scrollIndicators(.never)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            if model.groups.isEmpty {
                EmptyList(model: model)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.groups) { group in
                            HStack(alignment: .firstTextBaseline) {
                                Text(group.title)
                                    .font(.geist(14, .semibold))
                                    .accessibilityAddTraits(.isHeader)
                                Spacer(minLength: 8)
                                Text(CallText.days(group.rows.map(\.call.startedAt)))
                                    .font(.geist(12.5))
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                            .padding(.horizontal, 8)
                            .padding(.top, 22)
                            .padding(.bottom, 8)
                            VStack(spacing: 0) {
                                ForEach(group.rows) { row in
                                    CallRow(row: row, isOn: model.selection == row.id) {
                                        model.selection = row.id
                                    }
                                }
                            }
                            .padding(6)
                            .tile(radius: 20)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private var retention: String {
        let days = model.call.settings.storage.retentionDays
        return days <= 0 ? "Kept forever" : "Kept \(days) days"
    }
}

private struct EmptyList: View {
    let model: CallsModel

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !model.query.isEmpty {
                Text("Nothing matches \u{201C}\(model.query)\u{201D}")
                    .heading(17)
                Text("Search finds words in titles, summaries and transcripts.")
                    .font(.geist(13))
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                Text("No calls yet")
                    .heading(17)
                Text("Calls appear here once they end.")
                    .font(.geist(13))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            Spacer()
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

/// A call in the list: its initial and title, then its type, length and what is left to
/// do, with when it was on the right.
private struct CallRow: View {
    let row: CallsModel.Row
    let isOn: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                if row.isLive {
                    Circle()
                        .fill(Theme.recordingTint)
                        .overlay { Circle().fill(Theme.recording).frame(width: 9, height: 9) }
                        .frame(width: 36, height: 36)
                } else {
                    RoundGlyph(letter: initial)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.isLive ? "This call" : CallText.title(row.call))
                        .font(.geist(14.5, .medium))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let snippet = row.snippet {
                        Text(SnippetText.attributed(snippet))
                            .font(.geist(12.5))
                            .lineSpacing(2)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        meta
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(CallText.margin(row.call.startedAt))
                            .monospacedDigit()
                    }
                    .font(.geist(12.5))
                    .foregroundStyle(Theme.tertiaryText)
                }
                .padding(.top, 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .rowBackground(isOn: isOn, hovering: hovering, radius: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// The first letter or digit of the title, like a contact's initial.
    private var initial: String {
        CallText.title(row.call).first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "·"
    }

    private var meta: Text {
        if row.isLive {
            return Text("Live").foregroundColor(Theme.recordingText).fontWeight(.medium)
                + Text(", \(row.call.callType ?? "Call")")
        }
        var line = Text(row.call.callType ?? "Call")
        if let duration = row.call.duration {
            line = line + Text(", \(CallText.minutes(duration))")
        }
        if row.call.summaryDue {
            return line + Text(" · writing the summary")
        }
        if row.call.myOpenActionItems > 0 {
            return line + Text(" · ") + Text("\(row.call.myOpenActionItems) to do").foregroundColor(Theme.amber)
        }
        return line
    }

    private var spokenLabel: String {
        var parts = [
            row.isLive ? "This call, live" : CallText.title(row.call), row.call.callType ?? "Call",
            CallText.when(row.call.startedAt),
        ]
        if let duration = row.call.duration {
            parts.append(DisplayFormat.clock(duration))
        }
        if row.call.myOpenActionItems > 0 {
            parts.append("\(row.call.myOpenActionItems) to do")
        }
        if let snippet = row.snippet {
            parts.append("\(snippet.speaker.spokenName): \(snippet.text)")
        }
        return parts.joined(separator: ", ")
    }
}

private struct NoCallView: View {
    let model: CallsModel

    var body: some View {
        VStack(spacing: 0) {
            SectionBar { Spacer() }
            if Readiness.needsAttention(model.call.readiness) {
                SetupChecklist(model: model.call)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(model.calls.isEmpty ? "Your calls will be here" : "Pick a call")
                .heading(24)
            Text(
                model.calls.isEmpty
                    ? "After each call: what was said, the answers Listener suggested, and a summary with action items and a follow-up email."
                    : "Its summary, transcript and answers show here."
            )
            .font(.geist(14))
            .lineSpacing(4)
            .foregroundStyle(Theme.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
            .padding(.top, 10)
            Spacer()
            Spacer()
        }
    }
}

/// How a call is named and timed in the list and on its page.
enum CallText {
    /// The summary's title, or the call type and when, for a call without one.
    static func title(_ call: SavedCall) -> String {
        if let title = call.title, !title.isEmpty {
            return title
        }
        return "\(call.callType ?? "Call") on \(day(call.startedAt))"
    }

    /// The list's margin: the time for calls today and yesterday, whose day is in the
    /// heading, the weekday this week, and the date before that.
    static func margin(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        if Calendar.current.isDateInToday(date) || Calendar.current.isDateInYesterday(date) {
            formatter.dateFormat = "HH:mm"
        } else if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            formatter.dateFormat = "EEE"
        } else {
            formatter.dateFormat = "d MMM"
        }
        return formatter.string(from: date)
    }

    /// The days a group of calls covers, e.g. "Wed 28 Oct" or "22 to 23 Oct".
    static func days(_ dates: [Date]) -> String {
        let calendar = Calendar.current
        guard let first = dates.min(), let last = dates.max() else {
            return ""
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        if calendar.isDate(first, inSameDayAs: last) {
            formatter.dateFormat = "EEE d MMM"
            return formatter.string(from: first)
        }
        formatter.dateFormat = "d MMM"
        let end = formatter.string(from: last)
        formatter.dateFormat = calendar.isDate(first, equalTo: last, toGranularity: .month) ? "d" : "d MMM"
        return "\(formatter.string(from: first)) to \(end)"
    }

    /// "19 min", or "under a minute".
    static func minutes(_ seconds: Double) -> String {
        seconds < 60 ? "under a minute" : "\(Int((seconds / 60).rounded())) min"
    }

    /// "Monday 27 October", or with the year when it is not this year's.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat =
            Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "EEEE d MMMM" : "EEEE d MMMM yyyy"
        return formatter.string(from: date)
    }

    /// "Today 08:33", "Yesterday 16:10" or "Monday 20 October, 10:00".
    static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)
        if Calendar.current.isDateInToday(date) {
            return "Today \(time)"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday \(time)"
        }
        return "\(day(date)), \(time)"
    }
}

/// A search hit's line, with the words that matched picked out.
enum SnippetText {
    static func attributed(_ snippet: CallSearchIndex.Snippet) -> AttributedString {
        let text = snippet.text
        // Starts a little before the first match, so the match is on the first line.
        var start = text.startIndex
        if let first = snippet.matches.first?.lowerBound,
            text.distance(from: text.startIndex, to: first) > 40
        {
            start = text.index(first, offsetBy: -30)
            while start > text.startIndex, !text[text.index(before: start)].isWhitespace {
                start = text.index(before: start)
            }
        }
        var result = AttributedString(start > text.startIndex ? "\u{2026}" : "")
        result.append(AttributedString("\(snippet.speaker.spokenName): "))
        var cursor = start
        for match in snippet.matches where match.lowerBound >= cursor {
            result.append(AttributedString(text[cursor..<match.lowerBound]))
            var word = AttributedString(text[match])
            word.foregroundColor = Theme.text
            word.backgroundColor = Theme.amber.opacity(0.22)
            result.append(word)
            cursor = match.upperBound
        }
        result.append(AttributedString(text[cursor...]))
        return result
    }
}

/// The call being listened to: its answers and transcript as they come, and the
/// buttons for both, so the main window works as well as the floating one.
private struct LiveCallView: View {
    let model: CallsModel

    var body: some View {
        let call = model.call
        VStack(spacing: 0) {
            SectionBar {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Theme.recording)
                        .frame(width: 7, height: 7)
                        .background(Circle().fill(Theme.recording.opacity(0.2)).frame(width: 13, height: 13))
                    Text("Live")
                        .font(.geist(13, .semibold))
                    if let since = call.listeningSince {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Text(DisplayFormat.clock(context.date.timeIntervalSince(since)))
                                .font(.geist(13, .medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.recordingText)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Listening now")
                Spacer()
                AnswerButtons(call: call)
                Button {
                    model.showFloatingWindow?()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(IconButtonStyle())
                .help("Show the floating window")
                .accessibilityLabel("Show the floating window")
                Button(action: call.stop) {
                    Label {
                        Text("Stop")
                    } icon: {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.recording).frame(width: 8, height: 8)
                    }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(call.phase != .listening)
                .accessibilityLabel("Stop listening")
            }
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    if let id = call.answerID {
                        AnswerCardView(model: call, maxTextHeight: max(proxy.size.height * 0.5, 160))
                            .id(id)
                            .frame(maxWidth: 680)
                            .padding(.horizontal, 24)
                            .padding(.top, 16)
                            .padding(.bottom, 6)
                    }
                    if call.hasTranscript {
                        TranscriptView(model: call)
                            .frame(maxWidth: 680)
                            .padding(.horizontal, 8)
                    } else {
                        VStack(spacing: 8) {
                            Spacer()
                            Text("Listening")
                                .heading(24)
                            Text("The transcript appears here as people speak.")
                                .font(.geist(14))
                                .foregroundStyle(Theme.secondaryText)
                            Spacer()
                            Spacer()
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        }
    }
}

/// Quick, Deep and Recap, each with its hotkey in the tooltip.
struct AnswerButtons: View {
    let call: CallModel
    /// Shares out the width, as under Stop in the sidebar.
    var fills = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AnswerTier.allCases, id: \.self) { tier in
                let hotkey = call.activeHotkeys[tier.hotkeyAction]
                Button {
                    call.ask(tier)
                } label: {
                    // Side by side in the sidebar there is room for the words alone.
                    if fills {
                        Text(tier.title)
                            .frame(maxWidth: .infinity)
                    } else {
                        Label(tier.title, systemImage: tier.symbol)
                    }
                }
                .buttonStyle(PillButtonStyle(small: fills))
                .disabled(!call.canAsk)
                .help(hotkey.map { "\(tier.hotkeyAction.title): \($0.displayString)" } ?? tier.hotkeyAction.title)
                .accessibilityLabel(tier.hotkeyAction.title)
            }
        }
    }
}
