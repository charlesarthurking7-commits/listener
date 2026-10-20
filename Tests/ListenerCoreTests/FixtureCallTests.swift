import Foundation
import Testing

@testable import ListenerCore

/// One of the mock broker calls in the repository's Fixtures directory. The recordings
/// are read where they are rather than copied into the test bundle.
struct FixtureCall: Sendable, CustomTestStringConvertible {
    static let all = ["delayed-executions", "leverage-mirroring", "rate-limits-maintenance"].map(FixtureCall.init)

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    let name: String

    var testDescription: String { name }

    func script() throws -> ConversationScript {
        try ConversationScript.load(from: Self.root.appendingPathComponent("\(name)/script.json"))
    }

    func audio(_ speaker: Speaker) throws -> WAVAudio {
        try WAVReader.read(url: Self.root.appendingPathComponent("\(name)/\(speaker.rawValue.lowercased()).wav"))
    }

    /// The question Them asks before the longest pause, which is where the user would
    /// press the hotkey. In every fixture it is one the call itself cannot answer.
    static func hardestQuestion(in script: ConversationScript) -> ConversationScript.Line? {
        let lines = script.lines
        return lines.indices.dropLast()
            .filter { lines[$0].speaker == .them && lines[$0].text.contains("?") }
            .max { lines[$0 + 1].start - lines[$0].end < lines[$1 + 1].start - lines[$1].end }
            .map { lines[$0] }
    }
}

/// Speech the voice activity detector heard on one channel, in that channel's seconds.
private func voiceActivity(in samples: [Int16]) -> [ClosedRange<Double>] {
    var detector = VoiceActivityDetector(settings: TurnSettings())
    var events = detector.process(samples)
    if let end = detector.finish() {
        events.append(end)
    }
    var segments: [ClosedRange<Double>] = []
    var start: Double?
    for event in events {
        switch event {
        case .speechStarted(let at):
            start = at
        case .speechEnded(let at):
            if let begun = start {
                segments.append(begun...at)
            }
            start = nil
        }
    }
    return segments
}

/// The fixture recordings through the whole pipeline: replayed as fast as they can be
/// read, recognised by the scripted speech-to-text, answered and summarised by the
/// scripted model, and saved.
struct FixtureCallTests {
    /// How far the detector's speech may stray from a line's span. Spans start about
    /// 20 ms before the first loud 10 ms frame and end about 30 ms after the last one;
    /// the detector works in 20 ms frames.
    static let vadSlack = 0.06
    static let answer = "I'll check the figures and come back to you this afternoon."

    @Test(arguments: FixtureCall.all)
    func voiceActivityIsWhereTheScriptHasLines(_ call: FixtureCall) throws {
        let script = try call.script()
        for speaker in Speaker.allCases {
            let lines = script.lines.filter { $0.speaker == speaker }
            let speech = voiceActivity(in: try call.audio(speaker).samples)
            for line in lines {
                #expect(speech.contains { $0.overlaps(line.start...line.end) }, "no speech heard for \(line.text)")
            }
            for segment in speech {
                let inside = lines.contains { line in
                    segment.lowerBound >= line.start - Self.vadSlack && segment.upperBound <= line.end + Self.vadSlack
                }
                #expect(inside, "\(speaker.rawValue) speech at \(segment) outside every line")
            }
        }
    }

    @Test(arguments: FixtureCall.all)
    func theWholeCallReplaysThroughThePipeline(_ call: FixtureCall) async throws {
        let script = try call.script()
        let question = try #require(FixtureCall.hardestQuestion(in: script))
        let audio = [Speaker.me: try call.audio(.me), .them: try call.audio(.them)]
        let root = try temporaryDirectory("fixture-\(call.name)")
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = sessionSettings(directory: root)
        settings.storage.saveAudio = true
        let summarySettings = settings.summary.model
        let summary = "# \(script.title)\n\n## Summary\n\n- Covered in the call."
        let model = ScriptedLanguageModel(firstTokenDelay: .milliseconds(5), tokenInterval: .zero) { request in
            request.settings == summarySettings ? summary : Self.answer
        }
        var sources: [Speaker: ReplaySource] = [:]
        for speaker in Speaker.allCases {
            sources[speaker] = try ReplaySource(
                audio: try #require(audio[speaker]), speaker: speaker, pacing: .unpaced, name: call.name)
        }
        let session = CallSession(
            settings: settings,
            components: SessionComponents(
                sources: sources, speech: ScriptedSpeechToText(script: script), languageModel: model))

        // The hotkey goes down as soon as the question is on screen as a turn.
        let recorder = EventRecorder()
        let asked = AskOnce()
        let recording = recorder.record(session) { event in
            guard case .transcript(let snapshot) = event,
                snapshot.turns.contains(where: { $0.speaker == .them && $0.text == question.text }),
                await asked.first(snapshot)
            else {
                return
            }
            await session.requestAnswer(.quick)
        }
        try await session.start()
        await waitForReplay(sources)
        #expect(await eventually { await session.answers.count == 1 })
        await session.stop()
        await recording.value

        // Every line becomes one turn, in order, with its speaker and words. Times are
        // the script's plus however long after the session each channel started playing.
        let turns = await session.transcript.turns
        #expect(turns.map(\.speaker) == script.lines.map(\.speaker))
        #expect(turns.map(\.text) == script.lines.map(\.text))
        #expect(Set(turns.map(\.id)).count == turns.count)
        var lags: [Speaker: Double] = [:]
        for (turn, line) in zip(turns, script.lines) {
            let lag = lags[turn.speaker] ?? turn.end - line.end
            lags[turn.speaker] = lag
            #expect(lag >= 0 && lag < 1)
            #expect(abs(turn.end - line.end - lag) < 0.001, "end of \(line.text)")
            #expect(abs(turn.start - line.start - lag) < Self.vadSlack, "start of \(line.text)")
        }

        // The session's own voice activity found every line's speech and nothing else.
        let speech = await session.speechSegments
        #expect(speech.count < 64, "the timeline only keeps 64 segments")
        for line in script.lines {
            let lag = lags[line.speaker] ?? 0
            let heard = speech.contains { segment in
                segment.speaker == line.speaker && segment.start - lag < line.end
                    && (segment.end ?? .infinity) - lag > line.start
            }
            #expect(heard, "no speech heard for \(line.text)")
        }
        for segment in speech {
            let lag = lags[segment.speaker] ?? 0
            let inside = script.lines.contains { line in
                line.speaker == segment.speaker && segment.start - lag >= line.start - Self.vadSlack
                    && (segment.end ?? .infinity) - lag <= line.end + Self.vadSlack
            }
            #expect(inside, "\(segment.speaker.rawValue) speech at \(segment.start) outside every line")
        }

        // The answer was asked with the question in the prompt, after everything on
        // screen at the time, in order.
        let answerRequests = model.requests.filter { $0.settings == settings.answers.quick }
        try #require(answerRequests.count == 1)
        let prompt = answerRequests[0].userText
        #expect(prompt.contains("Them: \(question.text)\n"))
        let askedWith = try #require(await asked.snapshot)
        expectInOrder(askedWith.turns.map { "\($0.speaker.rawValue): \($0.text)\n" }, in: prompt)

        let answers = await session.answers
        try #require(answers.count == 1)
        let answer = answers[0]
        #expect(answer.text == Self.answer && answer.error == nil && !answer.fromDraft)
        #expect(recorder.answerText(id: 1) == Self.answer)
        #expect(recorder.finishedAnswers.map(\.id) == [1])
        // Replayed unpaced, audio runs far ahead of the clock, so the numbers mean
        // nothing; every stage must still have been measured.
        let latency = answer.latency
        for (stage, value) in [
            ("end of speech to hotkey", latency.endOfSpeechToHotkey), ("final to hotkey", latency.finalToHotkey),
            ("hotkey to request", latency.hotkeyToRequestSent), ("hotkey to first token", latency.hotkeyToFirstToken),
            ("hotkey to done", latency.hotkeyToDone), ("end of speech to first token", latency.endOfSpeechToFirstToken),
        ] {
            #expect(value != nil, "\(stage) missing")
        }

        // The summary was asked for with the whole call.
        let summaryRequests = model.requests.filter { $0.settings == summarySettings }
        try #require(summaryRequests.count == 1)
        let summaryPrompt = summaryRequests[0].userText
        #expect(!summaryPrompt.contains("Earlier parts of the call are not shown"))
        expectInOrder(script.lines.map { "\($0.speaker.rawValue): \($0.text)\n" }, in: summaryPrompt)

        // Speech-to-text heard both channels end to end; both model calls are priced.
        let cost = await session.cost
        let seconds = Double(try #require(audio[.me]).frameCount) / Double(AudioChunk.sampleRate)
        for speaker in Speaker.allCases {
            #expect(abs((cost.speechSeconds[speaker.rawValue] ?? 0) - seconds) < 0.001)
        }
        let perMinute = try #require(settings.prices.speechPerMinute["google"])
        #expect(abs(cost.speechCost - 2 * seconds / 60 * perMinute) < 1e-9)
        let haiku = try #require(cost.modelUsage["claude-haiku-5-5"])
        let sonnet = try #require(cost.modelUsage["claude-sonnet-5-5"])
        #expect(cost.modelUsage.count == 2)
        #expect(haiku == answer.usage)
        let prices = settings.prices.models
        #expect(abs(answer.cost - (prices["claude-haiku-5-5"]?.cost(of: haiku) ?? 0)) < 1e-12)
        #expect(abs(cost.modelCost - answer.cost - (prices["claude-sonnet-5-5"]?.cost(of: sonnet) ?? 0)) < 1e-12)
        #expect(answer.cost > 0 && cost.modelCost > answer.cost)
        #expect(recorder.costs.last == cost)

        // The session directory holds the whole call.
        let directory = try #require(await session.directory)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(
            Set(files) == ["transcript.jsonl", "answers.jsonl", "session.json", "summary.md", "me.wav", "them.wav"])
        #expect(try SessionStore.readTurns(in: directory) == turns)
        let savedAnswers = try SessionStore.readAnswers(in: directory)
        #expect(savedAnswers.map(\.id) == [1] && savedAnswers.first?.text == Self.answer)
        let record = try SessionStore.readRecord(in: directory)
        #expect(record.endedAt != nil)
        #expect(record.turnCount == script.lines.count)
        #expect(record.channels.map(\.speaker) == [.me, .them])
        #expect(record.answers.map(\.latency) == [latency])
        #expect(record.latency.endOfSpeechToFirstToken?.count == 1)
        #expect(record.cost == cost)
        #expect(record.summaryFile == SessionStore.summaryFile)
        let notes = try String(contentsOf: directory.appendingPathComponent(SessionStore.summaryFile), encoding: .utf8)
        #expect(notes == summary + "\n")
        for speaker in Speaker.allCases {
            let saved = try WAVReader.read(url: directory.appendingPathComponent(SessionStore.audioFile(for: speaker)))
            #expect(saved.samples == audio[speaker]?.samples, "saved \(speaker.rawValue) audio")
        }

        #expect(recorder.warnings.isEmpty)
        #expect(recorder.all.last == .stopped(directory: directory.path))
    }
}

/// Each of `parts` occurs in `text`, one after the other.
private func expectInOrder(_ parts: [String], in text: String, sourceLocation: SourceLocation = #_sourceLocation) {
    var rest = text[...]
    for part in parts {
        guard let range = rest.range(of: part) else {
            Issue.record("\"\(part)\" missing or out of order", sourceLocation: sourceLocation)
            return
        }
        rest = rest[range.upperBound...]
    }
}
