import Foundation

/// How much has been dictated, for the main window's Insights: totals per day in
/// dictation-stats.json, and which apps they went into. Counts only, never the words.
public struct DictationStats: Sendable, Equatable, Codable {
    public struct Totals: Sendable, Equatable, Codable {
        public var dictations = 0
        public var words = 0
        /// Time spent speaking, from fn fn to the fn that stops it.
        public var seconds = 0.0
        /// Words by the app they went into, keyed by its bundle ID (or its name, for the
        /// rare app without one).
        public var apps: [String: Int] = [:]

        public init() {}

        /// Files from before apps were counted have no `apps`.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            dictations = try container.decode(Int.self, forKey: .dictations)
            words = try container.decode(Int.self, forKey: .words)
            seconds = try container.decode(Double.self, forKey: .seconds)
            apps = try container.decodeIfPresent([String: Int].self, forKey: .apps) ?? [:]
        }

        /// Words per minute of speaking, once there is enough speaking for it to mean much.
        public var wordsPerMinute: Int? {
            seconds >= Self.minimumSeconds ? Int((Double(words) / (seconds / 60)).rounded()) : nil
        }

        /// How long typing the words would take at `typingWPM`, less the time spent
        /// saying them.
        public func timeSaved(typingWPM: Double = DictationStats.typingWPM) -> Double {
            max(0, Double(words) / typingWPM * 60 - seconds)
        }

        static let minimumSeconds = 20.0

        static func + (lhs: Totals, rhs: Totals) -> Totals {
            var sum = lhs
            sum.dictations += rhs.dictations
            sum.words += rhs.words
            sum.seconds += rhs.seconds
            sum.apps.merge(rhs.apps, uniquingKeysWith: +)
            return sum
        }
    }

    /// Days dictated on in a row, and the most there have been.
    public struct Streak: Sendable, Equatable {
        public var current = 0
        public var longest = 0
    }

    /// A typical typing speed, which time saved is measured against.
    public static let typingWPM = 40.0

    /// By local date, as "2026-10-27".
    public var days: [String: Totals] = [:]
    /// The name each app in `Totals.apps` had when it was last dictated into.
    public var appNames: [String: String] = [:]

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        days = try container.decode([String: Totals].self, forKey: .days)
        appNames = try container.decodeIfPresent([String: String].self, forKey: .appNames) ?? [:]
    }

    public mutating func record(
        words: Int, seconds: Double, appID: String? = nil, appName: String? = nil, at date: Date,
        calendar: Calendar = .current
    ) {
        guard words > 0 else {
            return
        }
        let key = Self.key(for: date, calendar: calendar)
        days[key, default: Totals()].dictations += 1
        days[key, default: Totals()].words += words
        days[key, default: Totals()].seconds += max(seconds, 0)
        if let app = appID ?? appName {
            days[key, default: Totals()].apps[app, default: 0] += words
            appNames[app] = appName ?? app
        }
    }

    public var total: Totals {
        days.values.reduce(Totals(), +)
    }

    public func totals(on date: Date, calendar: Calendar = .current) -> Totals? {
        days[Self.key(for: date, calendar: calendar)]
    }

    /// Since the start of `now`'s week, which starts on the calendar's first weekday.
    public func thisWeek(now: Date = Date(), calendar: Calendar = .current) -> Totals {
        guard let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            return Totals()
        }
        let first = Self.key(for: start, calendar: calendar)
        return days.filter { $0.key >= first }.values.reduce(Totals(), +)
    }

    /// Working days dictated on in a row: a weekend without dictation doesn't break a
    /// streak, and today doesn't until it is over.
    public func streak(now: Date = Date(), calendar: Calendar = .current) -> Streak {
        guard let first = days.keys.min().flatMap({ Self.date(fromKey: $0, calendar: calendar) }) else {
            return Streak()
        }
        let today = Self.key(for: now, calendar: calendar)
        var streak = Streak()
        var run = 0
        var day = first
        var key = Self.key(for: day, calendar: calendar)
        while key <= today {
            if days[key] != nil {
                run += 1
                streak.longest = max(streak.longest, run)
            } else if !calendar.isDateInWeekend(day), key != today {
                run = 0
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else {
                break
            }
            day = next
            key = Self.key(for: day, calendar: calendar)
        }
        streak.current = run
        return streak
    }

    /// Words as a person counts them: runs of text with a letter or digit in, leaving out
    /// the "-" or "1." that starts a list item.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline).reduce(0) { count, line in
            var words = line.split(whereSeparator: \.isWhitespace)
            if let first = words.first, first.count > 1, first.last == "." || first.last == ")",
                first.dropLast().allSatisfy(\.isNumber)
            {
                words.removeFirst()
            }
            return count + words.filter { $0.contains { $0.isLetter || $0.isNumber } }.count
        }
    }

    /// The stats in `file`: none yet when there is no file, and nil when it can't be read,
    /// so that it is never written over.
    public static func load(from file: URL) -> DictationStats? {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return DictationStats()
        }
        guard let data = try? Data(contentsOf: file) else {
            return nil
        }
        return try? JSONDecoder().decode(DictationStats.self, from: data)
    }

    public func save(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    static func key(for date: Date, calendar: Calendar) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    static func date(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            return nil
        }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
