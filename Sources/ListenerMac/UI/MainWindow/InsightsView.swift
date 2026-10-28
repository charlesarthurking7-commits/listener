import ListenerCore
import SwiftUI

/// How Listener is used: how much you dictate, how fast, into which apps and how often,
/// and what the last 30 days of calls came to.
struct InsightsView: View {
    let model: InsightsModel

    var body: some View {
        VStack(spacing: 0) {
            SectionBar {
                Text("Insights")
                    .font(.geist(15, .semibold))
                    .tracking(-0.15)
                Text("How you use Listener, counted on this Mac")
                    .font(.geist(12))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Dictation")
                    if model.stats.total.dictations == 0 {
                        Text(
                            "Press fn twice in any app and speak. How much you dictate, how fast, into which apps and on which days shows here after your first dictation."
                        )
                        .font(.geist(12.5))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560, alignment: .leading)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                    } else {
                        DictationCards(stats: model.stats)
                        HStack(alignment: .top, spacing: 14) {
                            AppsCard(model: model)
                            StreakCard(stats: model.stats)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    SectionLabel("Calls, last \(InsightsModel.callDays) days")
                        .padding(.top, 14)
                    CallsCard(totals: model.recentCalls)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
        }
    }
}

private struct DictationCards: View {
    let stats: DictationStats

    var body: some View {
        let total = stats.total
        let typing = Double(total.words) / DictationStats.typingWPM * 60
        HStack(spacing: 14) {
            InsightCard(title: "Words dictated") {
                BigNumber(text: total.words.formatted())
            } detail: {
                Fact(label: "This week", value: stats.thisWeek().words.formatted())
                Fact(label: "Dictations", value: total.dictations.formatted())
            }
            InsightCard(title: "Words per minute") {
                BigNumber(text: total.wordsPerMinute.map { "\($0)" } ?? "\u{2013}")
            } detail: {
                if let wpm = total.wordsPerMinute {
                    let top = max(Double(wpm), DictationStats.typingWPM)
                    SpeedBar(label: "You", wpm: wpm, fraction: Double(wpm) / top, tint: Theme.accent)
                    SpeedBar(
                        label: "Typing", wpm: Int(DictationStats.typingWPM), fraction: DictationStats.typingWPM / top,
                        tint: Theme.tertiaryText)
                } else {
                    Text("Shows once you've spoken for 20 seconds.")
                        .font(.geist(12))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .help("Words a minute while you speak, from fn fn to fn, pauses included, against typing at 40")
            InsightCard(title: "Time saved") {
                BigNumber(text: DisplayFormat.span(total.timeSaved()))
            } detail: {
                Fact(label: "Typing it at 40 wpm", value: DisplayFormat.span(typing))
                Fact(label: "Saying it", value: DisplayFormat.span(total.seconds))
            }
            .help("How much longer typing the words would have taken than saying them")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A card with a heading, one big figure, and a couple of lines under a hairline.
private struct InsightCard<Value: View, Detail: View>: View {
    let title: String
    @ViewBuilder let value: Value
    @ViewBuilder let detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title)
            value
                .padding(.top, 10)
            Spacer(minLength: 14)
            Hairline()
            VStack(alignment: .leading, spacing: 8) {
                detail
            }
            .padding(.top, 12)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

private struct BigNumber: View {
    let text: String
    var unit: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .font(.geistMono(28, .medium))
                .tracking(-0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let unit {
                Text(unit)
                    .font(.geist(13))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

private struct Fact: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.geistMono(12))
        }
        .font(.geist(12))
    }
}

private struct SpeedBar: View {
    let label: String
    let wpm: Int
    let fraction: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 44, alignment: .leading)
            Meter(fraction: fraction, tint: tint)
            Text("\(wpm)")
                .font(.geistMono(12))
                .frame(minWidth: 26, alignment: .trailing)
        }
        .font(.geist(12))
    }
}

/// A thin bar filled to `fraction` of its track.
private struct Meter: View {
    let fraction: Double
    var tint = Theme.accent

    var body: some View {
        Capsule()
            .fill(Theme.selection)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
    }
}

private struct AppsCard: View {
    let model: InsightsModel

    var body: some View {
        let (apps, others, otherWords) = model.topApps(5)
        let counted = apps.reduce(otherWords) { $0 + $1.words }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Where you dictate")
                Spacer()
                if counted > 0 {
                    let count = apps.count + others
                    Text(count == 1 ? "1 app" : "\(count) apps")
                        .font(.geist(11.5))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            if counted == 0 {
                VStack(spacing: 10) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 17, weight: .medium))
                    Text("The apps you dictate into show here from your next dictation.")
                        .font(.geist(12))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.tertiaryText)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    ForEach(apps) { app in
                        AppRow(
                            icon: app.icon, name: app.name, words: app.words, share: Double(app.words) / Double(counted)
                        )
                    }
                    if others > 0 {
                        AppRow(
                            icon: nil, name: others == 1 ? "1 other app" : "\(others) other apps", words: otherWords,
                            share: Double(otherWords) / Double(counted))
                    }
                }
                .padding(.top, 16)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

private struct AppRow: View {
    let icon: NSImage?
    let name: String
    let words: Int
    let share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Group {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.selection, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                .frame(width: 18, height: 18)
                Text(name)
                    .font(.geist(12.5, .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(words == 1 ? "1 word" : "\(words.formatted()) words")
                    .font(.geistMono(11.5))
                    .foregroundStyle(Theme.secondaryText)
                Text(share < 0.01 ? "<1%" : "\(Int((share * 100).rounded()))%")
                    .font(.geistMono(11.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(minWidth: 34, alignment: .trailing)
            }
            Meter(fraction: share)
                .padding(.leading, 26)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StreakCard: View {
    let stats: DictationStats

    var body: some View {
        let streak = stats.streak()
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionLabel("Streak")
                    Spacer()
                    Text("Longest \(streak.longest) \(streak.longest == 1 ? "day" : "days")")
                        .font(.geist(11.5))
                        .foregroundStyle(Theme.tertiaryText)
                }
                BigNumber(text: "\(streak.current)", unit: streak.current == 1 ? "day" : "days")
                    .padding(.top, 10)
            }
            .accessibilityElement(children: .combine)
            .help("Working days you've dictated on in a row. A weekend without dictation doesn't break it.")
            Spacer(minLength: 16)
            ActivityGrid(stats: stats)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

/// A square for each day of the last few months, as many weeks as fit, shaded by how
/// much was dictated. Hovering a day says what it was.
private struct ActivityGrid: View {
    let stats: DictationStats
    @State private var width: CGFloat = 0
    @State private var hovered: Date?

    private nonisolated static let gap: CGFloat = 3
    private static let targetCell: CGFloat = 14
    private static let labelWidth: CGFloat = 30
    private nonisolated static let monthHeight: CGFloat = 20
    private static let levels: [Double] = [0.3, 0.5, 0.75, 1]

    private struct Layout {
        var weeks: Int
        var cell: CGFloat
        var start: Date
        var today: Date
        var busiest: Int

        var height: CGFloat { ActivityGrid.monthHeight + 7 * cell + 6 * ActivityGrid.gap }

        func day(column: Int, row: Int, calendar: Calendar) -> Date? {
            calendar.date(byAdding: .day, value: column * 7 + row, to: start)
        }
    }

    var body: some View {
        let calendar = Calendar.current
        let layout = layout(calendar: calendar)
        VStack(alignment: .leading, spacing: 12) {
            Canvas { context, _ in
                draw(layout, calendar: calendar, in: &context)
            }
            .frame(height: layout.height)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = day(at: point, in: layout, calendar: calendar)
                case .ended: hovered = nil
                }
            }
            HStack(spacing: 8) {
                Text(caption(layout, calendar: calendar))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text("Less")
                        .padding(.trailing, 3)
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color(level: level))
                            .frame(width: 9, height: 9)
                    }
                    Text("More")
                        .padding(.leading, 3)
                }
                .accessibilityHidden(true)
            }
            .font(.geist(11.5))
            .foregroundStyle(Theme.tertiaryText)
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
    }

    private func layout(calendar: Calendar) -> Layout {
        let grid = max(0, width - Self.labelWidth)
        let weeks = min(53, max(8, Int((grid + Self.gap) / (Self.targetCell + Self.gap))))
        let cell = max(4, (grid - CGFloat(weeks - 1) * Self.gap) / CGFloat(weeks))
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let start = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? thisWeek
        var layout = Layout(weeks: weeks, cell: cell, start: start, today: today, busiest: 0)
        for offset in 0..<(weeks * 7) {
            if let day = calendar.date(byAdding: .day, value: offset, to: start), day <= today {
                layout.busiest = max(layout.busiest, stats.totals(on: day, calendar: calendar)?.words ?? 0)
            }
        }
        return layout
    }

    private func level(for day: Date, in layout: Layout, calendar: Calendar) -> Int {
        let words = stats.totals(on: day, calendar: calendar)?.words ?? 0
        guard words > 0, layout.busiest > 0 else {
            return 0
        }
        let share = Double(words) / Double(layout.busiest)
        return 1 + (Self.levels.firstIndex { share <= $0 } ?? Self.levels.count - 1)
    }

    private func color(level: Int) -> Color {
        level == 0 ? Theme.selection : Theme.accent.opacity(Self.levels[level - 1])
    }

    private func rect(column: Int, row: Int, in layout: Layout) -> CGRect {
        CGRect(
            x: Self.labelWidth + CGFloat(column) * (layout.cell + Self.gap),
            y: Self.monthHeight + CGFloat(row) * (layout.cell + Self.gap), width: layout.cell, height: layout.cell)
    }

    private func draw(_ layout: Layout, calendar: Calendar, in context: inout GraphicsContext) {
        let radius = min(3, layout.cell * 0.25)
        for row in 0..<7 {
            // Monday, Wednesday and Friday, wherever the week starts.
            let weekday = (calendar.firstWeekday - 1 + row) % 7 + 1
            if [2, 4, 6].contains(weekday) {
                let label = Text(calendar.shortWeekdaySymbols[weekday - 1])
                    .font(.geist(10))
                    .foregroundStyle(Theme.tertiaryText)
                context.draw(label, at: CGPoint(x: 0, y: rect(column: 0, row: row, in: layout).midY), anchor: .leading)
            }
        }
        var lastLabelEnd = -CGFloat.infinity
        for column in 0..<layout.weeks {
            for row in 0..<7 {
                guard let day = layout.day(column: column, row: row, calendar: calendar), day <= layout.today else {
                    continue
                }
                let box = rect(column: column, row: row, in: layout)
                context.fill(
                    Path(roundedRect: box, cornerRadius: radius, style: .continuous),
                    with: .color(color(level: level(for: day, in: layout, calendar: calendar))))
                if day == layout.today || day == hovered {
                    context.stroke(
                        Path(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius, style: .continuous),
                        with: .color(day == hovered ? Theme.text : Theme.tertiaryText), lineWidth: 1)
                }
                // A month's name over the week it starts in, where there is room.
                if calendar.component(.day, from: day) == 1 {
                    let label = context.resolve(
                        Text(day.formatted(.dateTime.month(.abbreviated)))
                            .font(.geist(10.5))
                            .foregroundStyle(Theme.tertiaryText))
                    let size = label.measure(in: CGSize(width: 100, height: 20))
                    if box.minX >= lastLabelEnd + 6, box.minX + size.width <= width {
                        context.draw(label, at: CGPoint(x: box.minX, y: 0), anchor: .topLeading)
                        lastLabelEnd = box.minX + size.width
                    }
                }
            }
        }
    }

    private func day(at point: CGPoint, in layout: Layout, calendar: Calendar) -> Date? {
        let step = layout.cell + Self.gap
        let column = Int(((point.x - Self.labelWidth) / step).rounded(.down))
        let row = Int(((point.y - Self.monthHeight) / step).rounded(.down))
        guard point.x >= Self.labelWidth, point.y >= Self.monthHeight, (0..<layout.weeks).contains(column),
            (0..<7).contains(row), let day = layout.day(column: column, row: row, calendar: calendar),
            day <= layout.today
        else {
            return nil
        }
        return day
    }

    private func caption(_ layout: Layout, calendar: Calendar) -> String {
        if let hovered {
            let words = stats.totals(on: hovered, calendar: calendar)?.words ?? 0
            let date = hovered.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            return "\(date): " + (words == 0 ? "no dictation" : words == 1 ? "1 word" : "\(words.formatted()) words")
        }
        let days = (0..<(layout.weeks * 7)).filter { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: layout.start), day <= layout.today else {
                return false
            }
            return stats.totals(on: day, calendar: calendar) != nil
        }
        .count
        return "\(days) \(days == 1 ? "day" : "days") in the last \(layout.weeks) weeks"
    }
}

private struct CallsCard: View {
    let totals: InsightsModel.CallTotals

    var body: some View {
        if totals.calls == 0 {
            Text("No calls in the last \(InsightsModel.callDays) days.")
                .font(.geist(12.5))
                .foregroundStyle(Theme.secondaryText)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        } else {
            HStack(spacing: 0) {
                Stat(value: totals.calls.formatted(), label: totals.calls == 1 ? "call" : "calls")
                VerticalHairline()
                Stat(value: DisplayFormat.span(totals.seconds), label: "on calls")
                VerticalHairline()
                Stat(value: totals.answers.formatted(), label: totals.answers == 1 ? "answer" : "answers")
                VerticalHairline()
                Stat(value: totals.openToDos.formatted(), label: totals.openToDos == 1 ? "to-do open" : "to-dos open")
            }
            .fixedSize(horizontal: false, vertical: true)
            .card()
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.geistMono(20, .medium))
                .tracking(-0.4)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.geist(11.5))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
