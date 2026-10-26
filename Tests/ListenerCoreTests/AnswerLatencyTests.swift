import Foundation
import Testing

@testable import ListenerCore

/// Which instants each answer latency stage is measured between, driven chunk by chunk
/// so the hotkey lands at an exact point in the audio.
struct AnswerLatencyTests {
    private struct Call {
        let session: CallSession
        let them: PushSource
        let model: ScriptedLanguageModel
        let root: URL
    }

    private func call(_ script: ConversationScript, seconds: Double) throws -> Call {
        let root = try temporaryDirectory("latency")
        let audio = scriptAudio(script, speaker: .them, seconds: seconds, frequency: 200)
        let them = PushSource(speaker: .them, samples: audio.samples)
        let model = tradeModel()
        let session = CallSession(
            settings: sessionSettings(directory: root),
            components: SessionComponents(
                sources: [.them: them], speech: ScriptedSpeechToText(script: script), languageModel: model))
        return Call(session: session, them: them, model: model, root: root)
    }

    /// The detector only confirms that speech has ended a fifth of a second after it
    /// did, so a quick hotkey arrives while the speech still looks to be going on. It
    /// must still be measured from that speech, not from the pause before it.
    @Test func aHotkeyJustAfterTheSpeakerStopsIsMeasuredFromThatSpeech() async throws {
        let script = ConversationScript(
            title: "two sentences",
            lines: [
                .init(speaker: .them, start: 0.5, end: 1.5, text: "That is the first part."),
                .init(speaker: .them, start: 2.0, end: 3.0, text: "Can you check the second?"),
            ])
        let call = try call(script, seconds: 5)
        defer { try? FileManager.default.removeItem(at: call.root) }
        let session = call.session
        try await session.start()

        call.them.play(until: 3.1)
        #expect(await eventually { await session.transcript.interim[.them] == script.lines[1].text })
        #expect(await session.speechSegments.last?.end == nil)
        // Pressed a tenth of a second after the speech stopped, however long it took to get here.
        await session.requestAnswer(.quick, pressedAt: try #require(call.them.capturedAt(3.1)))
        call.them.play(until: 5)
        #expect(await eventually { await session.answers.count == 1 })
        await session.stop()

        let answer = try #require(await session.answers.first)
        let latency = answer.latency
        let speechToHotkey = try #require(latency.endOfSpeechToHotkey)
        #expect(abs(speechToHotkey - 100) < 1)
        let firstToken = try #require(latency.hotkeyToFirstToken)
        let speechToFirstToken = try #require(latency.endOfSpeechToFirstToken)
        #expect(abs(speechToFirstToken - (speechToHotkey + firstToken)) <= 0.2)
        // The question was still interim at the hotkey; its final came after.
        #expect(try #require(latency.finalToHotkey) < 0)
        #expect(try #require(call.model.requests.first).userText.contains("Them: Can you check the second?"))

        let saved = try SessionStore.readRecord(in: try #require(await session.directory))
        #expect(saved.answers.map(\.latency) == [latency])
    }

    /// When the speaker has already started again at the hotkey, the user is answering
    /// what came before, so that is what the answer is measured from.
    @Test func aHotkeyAfterTheSpeakerStartedAgainIsMeasuredFromTheSpeechBefore() async throws {
        let script = ConversationScript(
            title: "and another thing",
            lines: [
                .init(speaker: .them, start: 0.5, end: 1.5, text: "Can you check the fills?"),
                .init(speaker: .them, start: 2.5, end: 4.0, text: "And the margins too."),
            ])
        let call = try call(script, seconds: 5)
        defer { try? FileManager.default.removeItem(at: call.root) }
        let session = call.session
        try await session.start()

        call.them.play(until: 2.9)
        #expect(await eventually { await session.speechSegments.count == 2 })
        await session.requestAnswer(.quick, pressedAt: try #require(call.them.capturedAt(2.9)))
        call.them.play(until: 5)
        #expect(await eventually { await session.answers.count == 1 })
        await session.stop()

        let answer = try #require(await session.answers.first)
        #expect(abs(try #require(answer.latency.endOfSpeechToHotkey) - 1_400) < 1)
        // From the final of the question, not of what followed it.
        let question = try #require(await session.speechSegments.first)
        let finalAt = try #require(question.finalAt)
        #expect(abs(try #require(answer.latency.finalToHotkey) - (answer.askedAt - finalAt) * 1_000) < 0.1)
    }

    @Test func theSavedFiguresAreKeptPerTierWithoutDrafts() {
        func answer(_ tier: AnswerTier, firstToken: Double, fromDraft: Bool = false) -> AnswerRecord {
            var record = AnswerRecord(id: 0, tier: tier, model: "m", askedAt: 0, fromDraft: fromDraft)
            record.latency.hotkeyToFirstToken = firstToken
            return record
        }
        let record = SessionRecord(
            startedAt: Date(), channels: [], speechProvider: "x", settings: Settings(),
            answers: [
                answer(.quick, firstToken: 800), answer(.quick, firstToken: 1_000), answer(.deep, firstToken: 3_000),
                answer(.quick, firstToken: 0, fromDraft: true),
            ])
        #expect(record.latency.keys.sorted() == ["deep", "quick"])
        #expect(record.latency["quick"]?.hotkeyToFirstToken == .init(count: 2, p50: 900, p90: 980))
        #expect(record.latency["deep"]?.hotkeyToFirstToken?.count == 1)
    }
}
