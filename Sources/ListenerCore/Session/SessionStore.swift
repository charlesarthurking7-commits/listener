import Foundation

/// A session saved on disk, as listed for the user.
public struct SavedSession: Sendable, Equatable {
    public var directory: URL
    public var startedAt: Date
    /// Nil when the session never ended cleanly (the app crashed or was killed).
    public var duration: Double?
    public var turnCount: Int
    public var cost: CostSummary?
    public var hasSummary: Bool

    public init(
        directory: URL, startedAt: Date, duration: Double?, turnCount: Int, cost: CostSummary?, hasSummary: Bool
    ) {
        self.directory = directory
        self.startedAt = startedAt
        self.duration = duration
        self.turnCount = turnCount
        self.cost = cost
        self.hasSummary = hasSummary
    }
}

/// One session's directory, `<root>/<yyyy-MM-dd HH.mm.ss>/`:
///
/// - `transcript.jsonl`: one line per turn, appended as each turn closes, so a crash
///   loses at most the turn in progress,
/// - `answers.jsonl`: one line per answer, appended as each one ends, and again if its
///   timing is completed later,
/// - `session.json`: the SessionRecord, written at start and rewritten at the end,
/// - `summary.md`: the post-call summary,
/// - `me.wav`, `them.wav`: the 16 kHz audio, only when `StorageSettings.saveAudio` is on.
///
/// Not thread-safe: owned by one CallSession.
public final class SessionStore {
    public static let transcriptFile = "transcript.jsonl"
    public static let answersFile = "answers.jsonl"
    public static let recordFile = "session.json"
    public static let summaryFile = "summary.md"

    public static func audioFile(for speaker: Speaker) -> String {
        "\(speaker.rawValue.lowercased()).wav"
    }

    public let directory: URL
    private let transcript: FileHandle
    private let answers: FileHandle
    private var audio: [Speaker: WAVWriter] = [:]
    private var isClosed = false

    /// Creates a new, uniquely named session directory under `root`.
    public init(root: URL, startedAt: Date = Date(), saveAudio: Bool = false) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let name = Self.directoryName(for: startedAt)
        var directory = root.appendingPathComponent(name, isDirectory: true)
        var attempt = 1
        while true {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
                break
            } catch  where fileManager.fileExists(atPath: directory.path) && attempt < 100 {
                attempt += 1
                directory = root.appendingPathComponent("\(name) (\(attempt))", isDirectory: true)
            }
        }
        self.directory = directory
        transcript = try Self.createFile(directory.appendingPathComponent(Self.transcriptFile))
        answers = try Self.createFile(directory.appendingPathComponent(Self.answersFile))
        if saveAudio {
            for speaker in Speaker.allCases {
                let url = directory.appendingPathComponent(Self.audioFile(for: speaker))
                audio[speaker] = try WAVWriter(url: url, sampleRate: AudioChunk.sampleRate)
            }
        }
    }

    deinit {
        try? close()
    }

    public func append(_ turn: Turn) throws {
        try appendLine(turn, to: transcript)
    }

    public func append(_ answer: AnswerRecord) throws {
        try appendLine(answer, to: answers)
    }

    /// Does nothing unless the store was created with `saveAudio`.
    public func appendAudio(_ samples: [Int16], for speaker: Speaker) throws {
        try audio[speaker]?.append(samples)
    }

    public func write(_ record: SessionRecord) throws {
        try Self.encoder(pretty: true).encode(record)
            .write(to: directory.appendingPathComponent(Self.recordFile), options: .atomic)
    }

    @discardableResult
    public func writeSummary(_ markdown: String) throws -> URL {
        try Self.writeSummary(markdown, in: directory)
    }

    /// Closes the files and finalises the WAV headers. Safe to call more than once.
    public func close() throws {
        if isClosed {
            return
        }
        isClosed = true
        try transcript.close()
        try answers.close()
        for writer in audio.values {
            try writer.finish()
        }
    }

    private func appendLine(_ value: some Encodable, to handle: FileHandle) throws {
        var line = try Self.encoder(pretty: false).encode(value)
        line.append(UInt8(ascii: "\n"))
        // One write per line, so a crash leaves at most one truncated last line.
        try handle.write(contentsOf: line)
    }

    private static func createFile(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return try FileHandle(forWritingTo: url)
    }

    static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension SessionStore {
    /// `~/Library/Application Support/Listener/sessions` on every platform.
    public static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Listener/sessions", isDirectory: true)
    }

    /// `storage.directory` with `~` expanded, or the default root.
    public static func root(
        for storage: StorageSettings, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        guard let path = storage.directory, !path.isEmpty else {
            return defaultRoot(home: home)
        }
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// "2026-10-20 17.40.05" in the local time zone. Dots, not colons, because Finder
    /// shows colons as slashes.
    public static func directoryName(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2)) "
            + "\(pad(parts.hour, 2)).\(pad(parts.minute, 2)).\(pad(parts.second, 2))"
    }

    /// The start time encoded in a session directory's name, or nil when the name is
    /// not a session's (with or without a " (2)" style suffix).
    public static func startDate(fromDirectoryName name: String, calendar: Calendar = .current) -> Date? {
        let characters = Array(name)
        guard characters.count >= 19 else {
            return nil
        }
        let suffix = String(characters[19...])
        if !suffix.isEmpty {
            guard suffix.hasPrefix(" ("), suffix.hasSuffix(")"), Int(suffix.dropFirst(2).dropLast()) != nil else {
                return nil
            }
        }
        let separators: [Int: Character] = [4: "-", 7: "-", 10: " ", 13: ".", 16: "."]
        for (offset, separator) in separators where characters[offset] != separator {
            return nil
        }
        func number(_ range: Range<Int>) -> Int? {
            let text = String(characters[range])
            return text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber) ? Int(text) : nil
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
            let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
        else {
            return nil
        }
        let components = DateComponents(
            calendar: calendar, timeZone: calendar.timeZone, year: year, month: month, day: day, hour: hour,
            minute: minute, second: second)
        guard components.isValidDate(in: calendar) else {
            return nil
        }
        return calendar.date(from: components)
    }
}

extension SessionStore {
    /// The turns in a session's transcript.jsonl, ordered by start. A truncated last
    /// line, left by a crash mid-write, is skipped.
    public static func readTurns(in directory: URL) throws -> [Turn] {
        try readLines(Turn.self, from: directory.appendingPathComponent(transcriptFile)).sorted { $0.start < $1.start }
    }

    /// The answers in a session's answers.jsonl, by id. An answer whose timing was
    /// completed after it ended is saved again; its last line counts.
    public static func readAnswers(in directory: URL) throws -> [AnswerRecord] {
        let saved = try readLines(AnswerRecord.self, from: directory.appendingPathComponent(answersFile))
        let latest = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return latest.values.sorted { $0.id < $1.id }
    }

    public static func readRecord(in directory: URL) throws -> SessionRecord {
        try decoder().decode(SessionRecord.self, from: Data(contentsOf: directory.appendingPathComponent(recordFile)))
    }

    /// Writes summary.md into a session directory and returns its URL.
    @discardableResult
    public static func writeSummary(_ markdown: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(summaryFile)
        var text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        text.append("\n")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Every session under `root`, newest first. Folders that are not sessions are left
    /// out; sessions whose session.json is missing (a crash) are listed from what
    /// survived.
    public static func list(in root: URL) -> [SavedSession] {
        sessionDirectories(in: root).map { directory, startedAt in
            let header = try? decoder().decode(
                RecordHeader.self, from: Data(contentsOf: directory.appendingPathComponent(recordFile)))
            let turnCount = header?.turnCount ?? ((try? readTurns(in: directory))?.count ?? 0)
            let hasSummary = FileManager.default.fileExists(atPath: directory.appendingPathComponent(summaryFile).path)
            return SavedSession(
                directory: directory,
                startedAt: header?.startedAt ?? startedAt,
                duration: header?.endedAt.map { $0.timeIntervalSince(header?.startedAt ?? startedAt) },
                turnCount: turnCount,
                cost: header?.cost,
                hasSummary: hasSummary
            )
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    /// Deletes session directories under `root` that started more than `retentionDays`
    /// ago, judged by their names. Never touches anything that is not named like a
    /// session or holds neither a transcript nor a session record.
    /// `retentionDays` of zero or less keeps everything. Returns what was deleted.
    @discardableResult
    public static func deleteExpired(in root: URL, retentionDays: Int, now: Date = Date()) throws -> [URL] {
        guard retentionDays > 0 else {
            return []
        }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        var deleted: [URL] = []
        var firstError: (any Error)?
        for (directory, startedAt) in sessionDirectories(in: root) where startedAt < cutoff {
            do {
                try FileManager.default.removeItem(at: directory)
                deleted.append(directory)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
        return deleted
    }

    private static func sessionDirectories(in root: URL) -> [(URL, Date)] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                let startedAt = startDate(fromDirectoryName: url.lastPathComponent),
                [transcriptFile, recordFile].contains(where: {
                    FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
                })
            else {
                return nil
            }
            return (url, startedAt)
        }
    }

    private static func readLines<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> [Value] {
        let data = try Data(contentsOf: url)
        let decoder = decoder()
        var values: [Value] = []
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for (index, line) in lines.enumerated() {
            do {
                values.append(try decoder.decode(Value.self, from: Data(line)))
            } catch  where index == lines.count - 1 && data.last != UInt8(ascii: "\n") {
                break
            }
        }
        return values
    }

    /// The parts of session.json a listing needs, so a session saved by an older
    /// version with different settings still lists.
    private struct RecordHeader: Decodable {
        var startedAt: Date
        var endedAt: Date?
        var turnCount: Int
        var cost: CostSummary
    }
}
