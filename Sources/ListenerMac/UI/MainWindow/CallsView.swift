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
            VerticalHairline()
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
            SectionBar {
                SectionTitle(title: "Calls")
                Spacer()
                Text(retention)
                    .font(.geist(11.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .help("Keep calls for, in Settings under Storage and privacy: older calls are deleted at launch")
            }
            VStack(alignment: .leading, spacing: 10) {
                SearchField(prompt: "Search calls and what was said", text: $model.query)
                if model.callTypes.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            Button("All") { model.typeFilter = nil }
                                .buttonStyle(FilterChipStyle(isOn: model.typeFilter == nil))
                            ForEach(model.callTypes, id: \.self) { type in
                                Button(type) { model.typeFilter = model.typeFilter == type ? nil : type }
                                    .buttonStyle(FilterChipStyle(isOn: model.typeFilter == type))
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 2)
            if model.groups.isEmpty {
                EmptyList(model: model)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.groups) { group in
                            SectionLabel(group.title)
                                .padding(.horizontal, 10)
                                .padding(.top, 16)
                                .padding(.bottom, 6)
                            ForEach(group.rows) { row in
                                CallRow(row: row, isOn: model.selection == row.id) {
                                    model.selection = row.id
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
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
        VStack(spacing: 6) {
            Spacer()
            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !model.query.isEmpty {
                Text("Nothing matches \u{201C}\(model.query)\u{201D}")
                    .font(.geist(13, .medium))
                Text("Search finds words in titles, summaries and transcripts.")
                    .font(.geist(12))
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                Text("No calls yet")
                    .font(.geist(13, .medium))
                Text("Calls appear here once they end.")
                    .font(.geist(12))
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

private struct CallRow: View {
    let row: CallsModel.Row
    let isOn: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                Text(row.isLive ? "This call" : CallText.title(row.call))
                    .font(.geist(13, .medium))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let snippet = row.snippet {
                    Text(SnippetText.attributed(snippet))
                        .font(.geist(12))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 6) {
                    if row.isLive {
                        Text("Live")
                            .font(.geist(11, .semibold))
                            .foregroundStyle(Theme.recordingText)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(Theme.recordingTint, in: RoundedRectangle(cornerRadius: 5))
                    }
                    Text(row.call.callType ?? "Call")
                    Text("·").foregroundStyle(Theme.tertiaryText.opacity(0.7))
                    Text(CallText.time(row.call.startedAt))
                        .font(.geistMono(11.5))
                    if let duration = row.call.duration {
                        Text("·").foregroundStyle(Theme.tertiaryText.opacity(0.7))
                        Text(DisplayFormat.clock(duration))
                            .font(.geistMono(11.5))
                    }
                    Spacer(minLength: 4)
                    if row.call.summaryDue {
                        Text("Writing summary")
                            .font(.geist(11, .medium))
                            .foregroundStyle(Theme.tertiaryText)
                    } else if row.call.myOpenActionItems > 0 {
                        Text("\(row.call.myOpenActionItems) to do")
                            .font(.geist(11, .medium))
                            .foregroundStyle(Theme.amber)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(Theme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .font(.geist(11.5))
                .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowBackground(isOn: isOn, hovering: hovering, radius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
            Image(systemName: "waveform")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
            Text(model.calls.isEmpty ? "Your calls will be here" : "Pick a call")
                .font(.geist(15, .semibold))
                .padding(.top, 14)
            Text(
                model.calls.isEmpty
                    ? "After each call: what was said, the answers Listener suggested, and a summary with action items and a follow-up email."
                    : "Its summary, transcript and answers show here."
            )
            .font(.geist(12.5))
            .lineSpacing(2)
            .foregroundStyle(Theme.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            .padding(.top, 6)
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

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        if Calendar.current.isDateInToday(date) || Calendar.current.isDateInYesterday(date) {
            formatter.dateFormat = "HH:mm"
        } else if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            formatter.dateFormat = "EEE HH:mm"
        } else {
            formatter.dateFormat = "d MMM"
        }
        return formatter.string(from: date)
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
                                .font(.geistMono(12.5, .medium))
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
                .buttonStyle(SoftButtonStyle())
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
                        VStack(spacing: 6) {
                            Spacer()
                            Text("Listening")
                                .font(.geist(15, .semibold))
                            Text("The transcript appears here as people speak.")
                                .font(.geist(12.5))
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
    /// Shares out the width, as over Stop in the sidebar.
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
                .buttonStyle(SoftButtonStyle(small: fills))
                .disabled(!call.canAsk)
                .help(hotkey.map { "\(tier.hotkeyAction.title): \($0.displayString)" } ?? tier.hotkeyAction.title)
                .accessibilityLabel(tier.hotkeyAction.title)
            }
        }
    }
}
