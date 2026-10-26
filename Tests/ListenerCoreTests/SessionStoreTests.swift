import Foundation
import Testing

@testable import ListenerCore

final class SessionStoreTests {
    private let root: URL
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    init() throws {
        root = try temporaryDirectory("store")
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

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
        let paths = ListenerPaths(home: URL(fileURLWithPath: "/Users/trader", isDirectory: true))
        let defaultRoot = "/Users/trader/Library/Application Support/Listener/sessions"
        var storage = StorageSettings()
        #expect(SessionStore.root(for: storage, paths: paths).path == defaultRoot)
        storage.directory = "~/Calls"
        #expect(SessionStore.root(for: storage, paths: paths).path == "/Users/trader/Calls")
        storage.directory = "/Volumes/Archive/calls"
        #expect(SessionStore.root(for: storage, paths: paths).path == "/Volumes/Archive/calls")
        storage.directory = ""
        #expect(SessionStore.root(for: storage, paths: paths).path == defaultRoot)
    }

    @Test func writesEveryFileAndReadsThemBack() throws {
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
        let store = try SessionStore(root: root)
        try store.appendAudio([1], for: .me)
        try store.close()
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted()
        #expect(files == ["answers.jsonl", "transcript.jsonl"])
    }

    @Test func theCallTypeIsSavedForWritingTheSummaryAgain() throws {
        let store = try SessionStore(root: root)
        #expect(SessionStore.readCall(in: store.directory) == .none)
        let call = CallContext(
            callType: "Work call", instructions: "Keep answers short.",
            documents: [CallContext.Document(name: "runbook.pdf", text: "Restart the bridge before the open.")])
        try store.write(call)
        try store.write(
            SessionRecord(startedAt: Date(), channels: [], speechProvider: "x", settings: Settings(), call: call))
        try store.close()
        #expect(SessionStore.readCall(in: store.directory) == call)
        let record = try SessionStore.readRecord(in: store.directory)
        #expect(record.callType == "Work call" && record.documents == ["runbook.pdf"])
    }

    @Test func sessionsStartedInTheSameSecondGetTheirOwnDirectories() throws {
        let now = Date()
        let first = try SessionStore(root: root, startedAt: now)
        let second = try SessionStore(root: root, startedAt: now)
        #expect(first.directory != second.directory)
        #expect(second.directory.lastPathComponent == first.directory.lastPathComponent + " (2)")
    }

    @Test func turnsStillOpenWhenTheAppDiedAreReadBack() throws {
        // A crash or force quit mid-call: one turn finished, two still being spoken.
        let store = try SessionStore(root: root, startedAt: date(2026, 3, 7))
        let finished = Turn(id: 1, speaker: .them, text: "Can you check the batch?", start: 1, end: 3)
        try store.append(finished)
        try store.write(
            SessionRecord(startedAt: date(2026, 3, 7), channels: [], speechProvider: "x", settings: Settings()))
        try store.writeOpenTurns([
            Turn(id: 3, speaker: .them, text: "And the fills", start: 6, end: 8),
            Turn(id: 2, speaker: .me, text: "Yes, I'll look", start: 4, end: 5),
        ])
        #expect(try SessionStore.readTurns(in: store.directory).map(\.id) == [1, 2, 3])
        #expect(SessionStore.list(in: root).first?.turnCount == 3)

        // At Stop every turn is finished and saved, and the open ones go.
        try store.append(Turn(id: 2, speaker: .me, text: "Yes, I'll look now.", start: 4, end: 5.5))
        try store.append(Turn(id: 3, speaker: .them, text: "And the fills.", start: 6, end: 8.5))
        try store.writeOpenTurns([])
        #expect(
            try SessionStore.readTurns(in: store.directory).map(\.text) == [
                "Can you check the batch?", "Yes, I'll look now.", "And the fills.",
            ])
        #expect(
            !FileManager.default.fileExists(
                atPath: store.directory.appendingPathComponent(SessionStore.openTurnsFile).path))
    }

    @Test func aTruncatedLastLineIsSkipped() throws {
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

    /// `storage.directory` can point anywhere, so a folder that is merely named like a
    /// session must survive: only folders Listener wrote a session into are deleted.
    @Test func retentionLeavesFoldersThatHoldNoSession() throws {
        let folder = root.appendingPathComponent(SessionStore.directoryName(for: date(2025, 1, 1), calendar: .current))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("holiday".utf8).write(to: folder.appendingPathComponent("photo.jpg"))

        #expect(try SessionStore.deleteExpired(in: root, retentionDays: 30, now: date(2026, 10, 20)).isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("photo.jpg").path))
        #expect(SessionStore.list(in: root).isEmpty)
    }
}
