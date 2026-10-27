import Foundation
import Testing

@testable import ListenerCore

struct DictationStatsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    private func date(_ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @Test func addsUpEachDayAndOverall() {
        var stats = DictationStats()
        stats.record(words: 30, seconds: 15, at: date(26), calendar: calendar)
        stats.record(words: 50, seconds: 25, at: date(27), calendar: calendar)
        stats.record(words: 40, seconds: 20, at: date(27, hour: 23), calendar: calendar)
        stats.record(words: 0, seconds: 4, at: date(27), calendar: calendar)

        #expect(stats.days["2026-10-27"]?.dictations == 2 && stats.days["2026-10-27"]?.words == 90)
        #expect(stats.total.dictations == 3 && stats.total.words == 120 && stats.total.seconds == 60)
        #expect(stats.total.wordsPerMinute == 120)
    }

    @Test func thisWeekStartsOnMonday() {
        var stats = DictationStats()
        stats.record(words: 70, seconds: 30, at: date(25), calendar: calendar)  // Sunday
        stats.record(words: 20, seconds: 10, at: date(26), calendar: calendar)  // Monday
        stats.record(words: 30, seconds: 10, at: date(28), calendar: calendar)
        let week = stats.thisWeek(now: date(28, hour: 18), calendar: calendar)
        #expect(week.words == 50 && week.dictations == 2)
    }

    @Test func speedWaitsForEnoughSpeaking() {
        var stats = DictationStats()
        stats.record(words: 12, seconds: 6, at: date(27), calendar: calendar)
        #expect(stats.total.wordsPerMinute == nil)
    }

    @Test func countsWordsByApp() {
        var stats = DictationStats()
        stats.record(
            words: 30, seconds: 15, appID: "com.microsoft.Outlook", appName: "Outlook", at: date(26), calendar: calendar
        )
        stats.record(
            words: 20, seconds: 10, appID: "com.microsoft.Outlook", appName: "Microsoft Outlook", at: date(27),
            calendar: calendar)
        stats.record(words: 5, seconds: 3, appName: "Helper", at: date(27), calendar: calendar)
        stats.record(words: 8, seconds: 4, at: date(27), calendar: calendar)

        #expect(stats.total.apps == ["com.microsoft.Outlook": 50, "Helper": 5])
        #expect(stats.total.words == 63)
        #expect(stats.appNames == ["com.microsoft.Outlook": "Microsoft Outlook", "Helper": "Helper"])
    }

    @Test func readsFilesFromBeforeAppsWereCounted() throws {
        let json = #"{"days":{"2026-10-27":{"dictations":2,"seconds":40,"words":90}}}"#
        let stats = try JSONDecoder().decode(DictationStats.self, from: Data(json.utf8))
        #expect(stats.total.words == 90 && stats.total.apps.isEmpty && stats.appNames.isEmpty)
    }

    @Test func streakCountsWorkingDaysInARow() {
        var stats = DictationStats()
        for day in [12, 13, 14, 22, 23, 26] {  // Monday to Wednesday, then Thursday to Monday
            stats.record(words: 10, seconds: 5, at: date(day), calendar: calendar)
        }
        // Tuesday, not dictated on yet: the weekend and today leave the streak alone.
        #expect(stats.streak(now: date(27), calendar: calendar) == .init(current: 3, longest: 3))
        // Tuesday went by without any.
        #expect(stats.streak(now: date(28), calendar: calendar) == .init(current: 0, longest: 3))
    }

    @Test func weekendDictationAddsToTheStreak() {
        var stats = DictationStats()
        for day in [23, 24, 26, 27] {  // Friday, Saturday, Monday, Tuesday
            stats.record(words: 10, seconds: 5, at: date(day), calendar: calendar)
        }
        #expect(stats.streak(now: date(27, hour: 18), calendar: calendar) == .init(current: 4, longest: 4))
        #expect(DictationStats().streak(now: date(27), calendar: calendar) == .init())
    }

    @Test func timeSavedAgainstTyping() {
        var totals = DictationStats.Totals()
        totals.words = 400
        totals.seconds = 180
        #expect(totals.timeSaved(typingWPM: 40) == 420)
        totals.seconds = 900
        #expect(totals.timeSaved(typingWPM: 40) == 0)
    }

    @Test func countsWordsNotListMarkers() {
        #expect(DictationStats.wordCount("Thanks, Hannah. We hit 500.") == 5)
        #expect(DictationStats.wordCount("Next steps:\n- Send the report\n1. Call MT5 support\n2) Book a review") == 11)
        #expect(DictationStats.wordCount("  ") == 0)
    }

    @Test func savesAndLoadsWithoutWritingOverAFileItCannotRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("dictation-stats.json")
        #expect(DictationStats.load(from: file) == DictationStats())

        var stats = DictationStats()
        stats.record(words: 42, seconds: 18, at: date(27), calendar: calendar)
        try stats.save(to: file)
        #expect(DictationStats.load(from: file) == stats)

        try Data("not json".utf8).write(to: file)
        #expect(DictationStats.load(from: file) == nil)
    }
}
