import Foundation
import Testing

@testable import ListenerCore

/// The whole pipeline on a synthetic two-channel call: replayed audio, the voice
/// activity detector, scripted speech-to-text, turn detection, a hotkey answer
/// mid-call, cost, the summary and everything saved to disk.
struct EndToEndTests {
    static let speed = 8.0

    @Test func scriptedCallProducesTranscriptAnswerAndSavedSession() async throws {
        let root = try temporaryDirectory("e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = try scriptSources(tradeScript, seconds: 11, pacing: .realTime(speed: Self.speed))
        let model = tradeModel()
        let session = CallSession(
            settings: sessionSettings(directory: root),
            components: SessionComponents(
                sources: sources, speech: ScriptedSpeechToText(script: tradeScript), languageModel: model))

        let recorder = EventRecorder()
        let asked = AskOnce()
        let recording = recorder.record(session) { event in
            guard case .transcript(let snapshot) = event,
                snapshot.turns.contains(where: { $0.text.contains("EUR fills from this morning") }),
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

        // The transcript matches the script, in order, at replay speed. Each channel's
        // playback starts a moment after the session does, more on a busy machine, hence
        // a lag per channel.
        let turns = try #require(recorder.lastTranscript).turns
        #expect(turns.map(\.speaker) == tradeScript.lines.map(\.speaker))
        #expect(turns.map(\.text) == tradeScript.lines.map(\.text))
        // Ids follow the order finals arrived in, which on a busy machine need not be
        // the order of speech; they only have to be unique.
        #expect(Set(turns.map(\.id)) == [1, 2, 3, 4, 5])
        var lags: [Speaker: Double] = [:]
        for (turn, line) in zip(turns, tradeScript.lines) {
            let lag = lags[turn.speaker] ?? turn.start - line.start / Self.speed
            lags[turn.speaker] = lag
            #expect(lag >= 0 && lag < 2)
            #expect(abs(turn.start - line.start / Self.speed - lag) < 0.02, "start of \(line.text)")
            #expect(abs(turn.end - line.end / Self.speed - lag) < 0.02, "end of \(line.text)")
        }

        // The window hears each channel start and stop talking, in that order.
        for speaker in Speaker.allCases {
            var activity: [Bool] = []
            for event in recorder.all {
                if case .channelActivity(speaker, let isSpeaking) = event {
                    activity.append(isSpeaking)
                }
            }
            #expect(activity.first == true, "\(speaker.rawValue) never started speaking")
            #expect(activity.last == false, "\(speaker.rawValue) never stopped speaking")
            for (index, isSpeaking) in activity.enumerated() {
                #expect(isSpeaking == index.isMultiple(of: 2), "\(speaker.rawValue) activity must alternate")
            }
        }

        // The answer streamed the scripted reply, built from the transcript so far.
        let request = try #require(model.requests.first)
        let askedWith = try #require(await asked.snapshot)
        #expect(request.settings.model == "claude-haiku-5-5")
        #expect(request.userText.contains("Them: Hi, thanks for joining the call."))
        #expect(request.userText.contains("Them: Can you confirm the EUR fills from this morning?"))
        for turn in askedWith.turns {
            #expect(request.userText.contains("\(turn.speaker.rawValue): \(turn.text)"))
        }
        #expect(recorder.all.contains(.answerStarted(id: 1, tier: .quick, model: "claude-haiku-5-5")))
        #expect(recorder.answerText(id: 1) == tradeAnswer)
        let answer = try #require(recorder.finishedAnswers.first)
        // Nothing said after the hotkey is in the prompt. The hotkey reacts to an event,
        // so on a busy machine it can come after the next line has begun.
        let nextLine = tradeScript.lines[4]
        if answer.askedAt < nextLine.start / Self.speed + (lags[.them] ?? 0) {
            #expect(!request.userText.contains("Them: Great"))
        }
        #expect(answer.text == tradeAnswer)
        #expect(answer.error == nil)
        #expect(!answer.fromDraft)
        #expect(answer.usage == TokenUsage(inputTokens: 1_200, outputTokens: 40))
        #expect(answer.cost > 0)

        // Latency: every stage measured, in order, and plausible.
        let latency = answer.latency
        let speechToHotkey = try #require(latency.endOfSpeechToHotkey)
        let finalToHotkey = try #require(latency.finalToHotkey)
        let requestSent = try #require(latency.hotkeyToRequestSent)
        let firstToken = try #require(latency.hotkeyToFirstToken)
        let done = try #require(latency.hotkeyToDone)
        let speechToFirstToken = try #require(latency.endOfSpeechToFirstToken)
        #expect(speechToHotkey >= 0 && speechToHotkey < 10_000)
        // The hotkey came after the final it was waiting for, which came after the speech.
        #expect(finalToHotkey >= 0 && finalToHotkey <= speechToHotkey)
        #expect(requestSent >= 0 && requestSent < 10_000)
        #expect(firstToken >= 50 && firstToken < 10_000)
        #expect(done >= firstToken)
        #expect(abs(speechToFirstToken - (speechToHotkey + firstToken)) <= 0.2)

        // Cost covers speech on both channels and the model calls.
        let cost = await session.cost
        #expect(cost.speechCost > 0 && cost.modelCost > 0)
        for speaker in Speaker.allCases {
            #expect(abs((cost.speechSeconds[speaker.rawValue] ?? 0) - 11) < 0.01)
        }
        #expect(recorder.costs.last == cost)
        #expect(model.warmUpCount == 1)

        // Everything is on disk and reads back.
        let directory = try #require(await session.directory)
        #expect(recorder.stoppedDirectories == [directory.path])
        #expect(try SessionStore.readTurns(in: directory) == turns)
        #expect(try SessionStore.readAnswers(in: directory) == [answer])
        let record = try SessionStore.readRecord(in: directory)
        #expect(record.endedAt != nil)
        #expect(record.turnCount == 5)
        #expect(record.channels.map(\.speaker) == [.me, .them])
        #expect(record.speechProvider == "Scripted speech-to-text")
        #expect(record.answers.map(\.latency) == [latency])
        #expect(record.latency.hotkeyToFirstToken?.count == 1)
        #expect(record.latency.endOfSpeechToFirstToken?.p50 == speechToFirstToken)
        #expect(record.cost == cost)
        #expect(record.summaryFile == "summary.md")
        let summary = try String(contentsOf: directory.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(summary == tradeSummary + "\n")
        let summaryPath = directory.appendingPathComponent("summary.md").path
        #expect(recorder.all.suffix(4).contains(.summaryFinished(markdownFile: summaryPath)))
        #expect(recorder.all.contains(.summaryStarted))
        #expect(recorder.all.last == .stopped(directory: directory.path))
    }
}

/// True for the first caller only, remembering what it was asked with.
actor AskOnce {
    private(set) var snapshot: TranscriptSnapshot?

    func first(_ snapshot: TranscriptSnapshot) -> Bool {
        guard self.snapshot == nil else {
            return false
        }
        self.snapshot = snapshot
        return true
    }
}
