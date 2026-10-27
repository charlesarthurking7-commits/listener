import Foundation

/// How much has been dictated, for the main window: totals per day in
/// dictation-stats.json. Counts only, never the words themselves.
public struct DictationStats: Sendable, Equatable, Codable {
    public struct Totals: Sendable, Equatable, Codable {
        public var dictations = 0
        public var words = 0
        /// Time spent speaking, from fn fn to the fn that stops it.
        public var seconds = 0.0

        public init() {}

        /// Words per minute of speaking, once there is enough speaking for it to mean much.
        public var wordsPerMinute: Int? {
            seconds >= Self.minimumSeconds ? Int((Double(words) / (seconds / 60)).rounded()) : nil
        }

        static let minimumSeconds = 20.0

        static func + (lhs: Totals, rhs: Totals) -> Totals {
            var sum = lhs
            sum.dictations += rhs.dictations
            sum.words += rhs.words
            sum.seconds += rhs.seconds
            return sum
        }
    }

    /// By local date, as "2026-10-27".
    public var days: [String: Totals] = [:]

    public init() {}

    public mutating func record(words: Int, seconds: Double, at date: Date, calendar: Calendar = .current) {
        guard words > 0 else {
            return
        }
        let key = Self.key(for: date, calendar: calendar)
        days[key, default: Totals()].dictations += 1
        days[key, default: Totals()].words += words
        days[key, default: Totals()].seconds += max(seconds, 0)
    }

    public var total: Totals {
        days.values.reduce(Totals(), +)
    }

    /// Since the start of `now`'s week, which starts on the calendar's first weekday.
    public func thisWeek(now: Date = Date(), calendar: Calendar = .current) -> Totals {
        guard let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            return Totals()
        }
        let first = Self.key(for: start, calendar: calendar)
        return days.filter { $0.key >= first }.values.reduce(Totals(), +)
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
}
