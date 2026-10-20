import Foundation
import Testing

@testable import ListenerCore

struct SessionStoreTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9, _ minute: Int = 30, _ second: Int = 5)
        -> Date
    {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    @Test func directoryNamesRoundTrip() {
        let start = date(2026, 3, 7, 8, 5, 9)
        let name = SessionStore.directoryName(for: start, calendar: calendar)
        #expect(name == "2026-03-07 08.05.09")
        #expect(SessionStore.startDate(fromDirectoryName: name, calendar: calendar) == start)
        #expect(SessionStore.startDate(fromDirectoryName: name + " (2)", calendar: calendar) == start)
        for notASession in [
            "notes", "2026-03-07", "2026-03-07 08:05:09", "2026-13-07 08.05.09", "2026-03-07 08.05.09x",
            "2026-03-07 08.05.09 (x)",
        ] {
            #expect(SessionStore.startDate(fromDirectoryName: notASession, calendar: calendar) == nil, "\(notASession)")
        }
    }

    @Test func rootsFollowSettings() {
        let home = URL(fileURLWithPath: "/Users/trader", isDirectory: true)
        var storage = StorageSettings()
        #expect(
            SessionStore.root(for: storage, home: home).path
                == "/Users/trader/Library/Application Support/Listener/sessions")
        storage.directory = "~/Calls"
        #expect(SessionStore.root(for: storage, home: home).path == "/Users/trader/Calls")
        storage.directory = "/Volumes/Archive/calls"
        #expect(SessionStore.root(for: storage, home: home).path == "/Volumes/Archive/calls")
        storage.directory = ""
        #expect(SessionStore.root(for: storage, home: home) == SessionStore.defaultRoot(home: home))
    }

    @Test func writesEveryFileAndReadsThemBack() throws {
        let root = try temporaryDirectory("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let startedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let store = try SessionStore(root: root, startedAt: startedAt, saveAudio: true)
        #expect(store.directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(store.directory.lastPathComponent == SessionStore.directoryName(for: startedAt))

        let turns = [
            Turn(id: 2, speaker: .me, text: "Sure, \"quoted\" / ok", start: 3, end: 4),
            Turn(id: 1, speaker: .them, text: "Question?", start: 1, end: 2),
        ]
        for turn in turns {
            try store.append(turn)
        }
        let answer = AnswerRecord(
            id: 1, tier: .deep, model: "claude-sonnet-5-5", askedAt: 4.5, text: "Say yes.", fromDraft: true)
        try store.append(answer)
        try store.appendAudio([1, 2, 3], for: .me)
        try store.appendAudio([4, 5], for: .them)

        var record = SessionRecord(
            startedAt: startedAt, channels: [], speechProvider: "Scripted", settings: Settings(), turnCount: 2,
            answers: [answer])
        try store.write(record)
        record.endedAt = startedAt.addingTimeInterval(65)
        try store.write(record)
        let summary = try store.writeSummary("## Summary\n\nAll good.\n\n")
        try store.close()
        try store.close()

        let directory = store.directory
        #expect(try SessionStore.readTurns(in: directory) == turns.reversed())
        #expect(try SessionStore.readAnswers(in: directory) == [answer])
        #expect(try SessionStore.readRecord(in: directory) == record)
        #expect(try String(contentsOf: summary, encoding: .utf8) == "## Summary\n\nAll good.\n")
        #expect(try WAVReader.read(url: directory.appendingPathComponent("me.wav")).samples == [1, 2, 3])
        #expect(try WAVReader.read(url: directory.appendingPathComponent("them.wav")).samples == [4, 5])

        let lines = try String(contentsOf: directory.appendingPathComponent("transcript.jsonl"), encoding: .utf8)
        #expect(lines.split(separator: "\n").count == 2)
        #expect(lines.hasSuffix("\n"))
    }

    @Test func anAnswerSavedAgainReadsBackAsItsLastVersion() throws {
        let root = try temporaryDirectory("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var first = AnswerRecord(id: 1, tier: .quick, model: "claude-haiku-5-5", askedAt: 2, text: "Yes.")
        let second = AnswerRecord(id: 2, tier: .quick, model: "claude-haiku-5-5", askedAt: 5, text: "No.")
        try store.append(first)
        try store.append(second)
        // The first answer's speech only got its final after the second answer ended.
        first.latency.finalToHotkey = -250
        try store.append(first)
        try store.close()
        #expect(try SessionStore.readAnswers(in: store.directory) == [first, second])
    }

    @Test func noAudioFilesUnlessAsked() throws {
        let root = try temporaryDirectory("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        try store.appendAudio([1], for: .me)
        try store.close()
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted()
        #expect(files == ["answers.jsonl", "transcript.jsonl"])
    }

    @Test func sessionsStartedInTheSameSecondGetTheirOwnDirectories() throws {
        let root = try temporaryDirectory("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let first = try SessionStore(root: root, startedAt: now)
        let second = try SessionStore(root: root, startedAt: now)
        #expect(first.directory != second.directory)
        #expect(second.directory.lastPathComponent == first.directory.lastPathComponent + " (2)")
    }

    @Test func aTruncatedLastLineIsSkipped() throws {
        let root = try temporaryDirectory("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        try store.append(Turn(id: 1, speaker: .me, text: "Kept", start: 0, end: 1))
        try store.close()
        let url = store.directory.appendingPathComponent("transcript.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":2,\"speaker\":\"Me\",\"te".utf8))
        try handle.close()
        #expect(try SessionStore.readTurns(in: store.directory).map(\.text) == ["Kept"])
    }

    @Test func listsSessionsNewestFirst() throws {
        let root = try temporaryDirectory("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let older = Date(timeIntervalSince1970: 1_790_000_000)
        let newer = older.addingTimeInterval(3_600)

        let finished = try SessionStore(root: root, startedAt: older)
        try finished.append(Turn(id: 1, speaker: .me, text: "a", start: 0, end: 1))
        var record = SessionRecord(
            startedAt: older, endedAt: older.addingTimeInterval(90), channels: [], speechProvider: "x",
            settings: Settings(), turnCount: 7, cost: CostSummary(speechCost: 0.5))
        record.summaryFile = "summary.md"
        try finished.write(record)
        try finished.writeSummary("Done")
        try finished.close()

        // A session whose app crashed: no session.json, two turns on disk.
        let crashed = try SessionStore(root: root, startedAt: newer)
        try crashed.append(Turn(id: 1, speaker: .me, text: "a", start: 0, end: 1))
        try crashed.append(Turn(id: 2, speaker: .them, text: "b", start: 1, end: 2))
        try crashed.close()

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("not a session"), withIntermediateDirectories: true)

        let sessions = SessionStore.list(in: root)
        #expect(
            sessions.map(\.directory.lastPathComponent) == [
                crashed.directory.lastPathComponent, finished.directory.lastPathComponent,
            ])
        #expect(
            sessions[0].duration == nil && sessions[0].turnCount == 2 && sessions[0].cost == nil
                && !sessions[0].hasSummary)
        #expect(sessions[1].startedAt == older)
        #expect(sessions[1].duration == 90 && sessions[1].turnCount == 7 && sessions[1].hasSummary)
        #expect(sessions[1].cost?.speechCost == 0.5)
        #expect(SessionStore.list(in: root.appendingPathComponent("missing")).isEmpty)
    }

    @Test func retentionDeletesOnlyOldSessionDirectories() throws {
        let root = try temporaryDirectory("retention")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = date(2026, 10, 20)
        let fileManager = FileManager.default
        func make(_ name: String, directory: Bool = true) throws {
            let url = root.appendingPathComponent(name)
            if directory {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url.appendingPathComponent("transcript.jsonl"))
            } else {
                try Data("x".utf8).write(to: url)
            }
        }
        let old = SessionStore.directoryName(for: date(2026, 9, 1), calendar: .current)
        let recent = SessionStore.directoryName(for: date(2026, 10, 10), calendar: .current)
        try make(old)
        try make(old + " (2)")
        try make(recent)
        try make("2020-01-01 notes")
        try make("Archive")
        try make("2020-01-01 00.00.00.txt", directory: false)
        try make(SessionStore.directoryName(for: date(2020, 1, 1), calendar: .current), directory: false)

        let deleted = try SessionStore.deleteExpired(in: root, retentionDays: 30, now: now)
        #expect(Set(deleted.map(\.lastPathComponent)) == [old, old + " (2)"])
        let left = try fileManager.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left.count == 5)
        #expect(left.contains(recent) && left.contains("Archive") && left.contains("2020-01-01 notes"))

        #expect(try SessionStore.deleteExpired(in: root, retentionDays: 0, now: now.addingTimeInterval(1e9)).isEmpty)
        #expect(try SessionStore.deleteExpired(in: root.appendingPathComponent("missing"), retentionDays: 1).isEmpty)
    }
}
