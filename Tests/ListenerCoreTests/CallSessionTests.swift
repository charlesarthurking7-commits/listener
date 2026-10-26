import Foundation
import Synchronization
import Testing

@testable import ListenerCore

/// Speech-to-text whose first stream per speaker breaks on the first audio it gets.
final class FlakySpeech: SpeechToTextProvider, Sendable {
    let scripted: ScriptedSpeechToText
    private let broken = Mutex<Set<Speaker>>([])

    init(script: ConversationScript) {
        scripted = ScriptedSpeechToText(script: script)
    }

    var displayName: String { "Flaky" }

    func openStream(for speaker: Speaker) async throws -> any SpeechStream {
        if broken.withLock({ $0.insert(speaker).inserted }) {
            return BrokenStream()
        }
        return try await scripted.openStream(for: speaker)
    }
}

actor BrokenStream: SpeechStream {
    struct Failure: Error {}

    nonisolated let events: AsyncThrowingStream<SpeechEvent, any Error>
    private let continuation: AsyncThrowingStream<SpeechEvent, any Error>.Continuation

    init() {
        (events, continuation) = AsyncThrowingStream.makeStream(of: SpeechEvent.self)
    }

    func send(_ chunk: AudioChunk) async throws {
        throw Failure()
    }

    func finish() async {
        continuation.finish()
    }
}

/// Scripted speech-to-text that holds the finals of `holding` back until the test
/// releases them.
final class HeldFinalsSpeech: SpeechToTextProvider, Sendable {
    let script: ConversationScript
    let holding: Set<Speaker>
    private let streams = Mutex<[HeldFinalsStream]>([])

    init(script: ConversationScript, holding: Set<Speaker> = [.me, .them]) {
        self.script = script
        self.holding = holding
    }

    var displayName: String { "Held finals" }

    func openStream(for speaker: Speaker) async throws -> any SpeechStream {
        let lines = script.lines.filter { $0.speaker == speaker }
        let stream = HeldFinalsStream(
            ScriptRecognizer(lines: lines, finalDelay: 0.3), released: !holding.contains(speaker))
        streams.withLock { $0.append(stream) }
        return stream
    }

    func releaseFinals() async {
        for stream in streams.withLock({ $0 }) {
            await stream.release()
        }
    }
}

actor HeldFinalsStream: SpeechStream {
    nonisolated let events: AsyncThrowingStream<SpeechEvent, any Error>
    private let continuation: AsyncThrowingStream<SpeechEvent, any Error>.Continuation
    private var recognizer: ScriptRecognizer
    private var held: [SpeechEvent] = []
    private var released: Bool
    private var samples = 0

    init(_ recognizer: ScriptRecognizer, released: Bool) {
        (events, continuation) = AsyncThrowingStream.makeStream(of: SpeechEvent.self)
        self.recognizer = recognizer
        self.released = released
    }

    func send(_ chunk: AudioChunk) async throws {
        samples += chunk.samples.count
        deliver(recognizer.advance(to: Double(samples) / 16_000))
    }

    func release() {
        released = true
        deliver(held)
        held = []
    }

    func finish() async {
        released = true
        deliver(held + recognizer.finish(at: Double(samples) / 16_000))
        continuation.finish()
    }

    private func deliver(_ events: [SpeechEvent]) {
        for event in events {
            if event.kind == .final && !released {
                held.append(event)
            } else {
                continuation.yield(event)
            }
        }
    }
}

/// Streams a few words, then fails the way a refusal does.
struct RefusingModel: LanguageModelProvider {
    struct Refusal: Error, CustomStringConvertible {
        var description: String { "refused" }
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("Sure, the account "))
            continuation.finish(throwing: Refusal())
        }
    }

    func warmUp() async {}
}

final class CallSessionTests {
    private let root: URL

    init() throws {
        root = try temporaryDirectory("session")
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Setup {
        var session: CallSession
        var sources: [Speaker: ReplaySource]
        var recorder: EventRecorder
        var recording: Task<Void, Never>

        /// Plays the whole call, then stops it.
        func run() async throws {
            try await session.start()
            await waitForReplay(sources)
            await stop()
        }

        /// Stops the session and waits until the recorder has every event.
        func stop() async {
            await session.stop()
            await recording.value
        }
    }

    /// Given `sources`, the session captures from them instead of replaying the script,
    /// which still drives the scripted speech-to-text.
    private func setUp(
        script: ConversationScript = tradeScript, seconds: Double = 11, pacing: ReplaySource.Pacing = .unpaced,
        sources: [Speaker: any AudioCaptureSource]? = nil, speech: (any SpeechToTextProvider)? = nil,
        model: (any LanguageModelProvider)? = tradeModel(), call: CallContext = .none,
        configure: (inout Settings) -> Void = { _ in }
    ) throws -> Setup {
        var settings = sessionSettings(directory: root)
        configure(&settings)
        let replay = sources == nil ? try scriptSources(script, seconds: seconds, pacing: pacing) : [:]
        let session = CallSession(
            settings: settings,
            components: SessionComponents(
                sources: sources ?? replay, speech: speech ?? ScriptedSpeechToText(script: script),
                languageModel: model),
            call: call)
        let recorder = EventRecorder()
        return Setup(session: session, sources: replay, recorder: recorder, recording: recorder.record(session))
    }

    /// Them asks one question, played at 8x with drafts ahead on.
    private func draftSetUp(model: ScriptedLanguageModel) throws -> Setup {
        let script = ConversationScript(
            title: "draft", lines: [.init(speaker: .them, start: 0.5, end: 1.5, text: "Are the fills in?")])
        return try setUp(script: script, seconds: 4, pacing: .realTime(speed: 8), model: model) {
            $0.answers.draftAhead = true
        }
    }

    @Test func aSourceThatCannotStartStopsTheOthersAndLeavesNothingBehind() async throws {
        let me = FakeSource(.me)
        let them = FakeSource(.them, fails: true)
        let setup = try setUp(sources: [.me: me, .them: them], model: nil)

        await #expect(throws: FakeSource.Failure()) {
            try await setup.session.start()
        }
        #expect(me.stops == 1 && them.stops == 0)
        #expect(await !setup.session.isRunning)
        #expect(await setup.session.directory == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        await setup.stop()
        #expect(setup.recorder.all == [.stopped(directory: nil)])
    }

    @Test func startingTwiceAndStoppingTwiceAreHarmless() async throws {
        let me = FakeSource(.me)
        let setup = try setUp(sources: [.me: me], model: nil)
        let session = setup.session

        try await session.start()
        try await session.start()
        #expect(me.starts == 1)
        async let first: Void = session.stop()
        async let second: Void = session.stop()
        _ = await (first, second)
        await setup.stop()
        #expect(me.stops == 1)
        #expect(setup.recorder.stoppedDirectories.count == 1)
        try await session.start()
        #expect(me.starts == 1)
    }

    @Test func stopDuringStartWaitsForStartThenStops() async throws {
        let me = FakeSource(.me, startDelay: .milliseconds(200))
        let setup = try setUp(sources: [.me: me], model: nil)
        let session = setup.session

        let starting = Task { try await session.start() }
        try await Task.sleep(for: .milliseconds(50))
        await session.stop()
        try await starting.value
        await setup.recording.value
        #expect(me.stops == 1)
        #expect(await !session.isRunning)
        #expect(
            setup.recorder.all.first
                == .started(channels: [
                    ChannelInfo(speaker: .me, backend: "fake", device: "none", nativeFormat: "16 kHz")
                ]))
        #expect(setup.recorder.stoppedDirectories.count == 1)
    }

    @Test func theCallIsSavedBeforeItsSummaryIsWritten() async throws {
        // A summary takes a minute or more. The next call must not wait for it, and the
        // record says one is still due in case the app quits before it is written.
        let setup = try setUp(model: tradeModel(firstTokenDelay: .milliseconds(500)))
        try await setup.session.start()
        await waitForReplay(setup.sources)
        let stopping = Task { await setup.session.stop() }

        #expect(await eventually { setup.recorder.stoppedDirectories.count == 1 })
        #expect(!setup.recorder.all.contains { if case .summaryFinished = $0 { true } else { false } })
        let directory = URL(fileURLWithPath: try #require(setup.recorder.stoppedDirectories.first ?? nil))
        #expect(try SessionStore.readRecord(in: directory).summaryDue == true)

        await stopping.value
        await setup.recording.value
        let events = setup.recorder.all
        let stopped = try #require(events.firstIndex { if case .stopped = $0 { true } else { false } })
        #expect(events.firstIndex(of: .summaryStarted).map { $0 > stopped } == true)
        let record = try SessionStore.readRecord(in: directory)
        #expect(record.summaryDue == nil && record.summaryFile == "summary.md")
    }

    @Test func hotkeysOutsideACallAreIgnored() async throws {
        let model = tradeModel()
        let setup = try setUp(model: model)
        await setup.session.requestAnswer(.quick)
        await setup.session.cancelAnswer()
        try await setup.run()
        await setup.session.requestAnswer(.deep)
        await setup.session.cancelAnswer()
        // Only the summary asked the model anything.
        #expect(model.requests.count == 1)
        #expect(!setup.recorder.all.contains { if case .answerStarted = $0 { return true } else { return false } })
    }

    @Test func aChannelOfDigitalSilenceGetsOnePermissionWarning() async throws {
        let silentMe = ConversationScript(
            title: "monologue", lines: [.init(speaker: .them, start: 1, end: 3, text: "Hello?")])
        let setup = try setUp(script: silentMe, seconds: 31, model: nil)
        try await setup.run()
        let warnings = setup.recorder.warnings
        #expect(warnings.count == 1)
        #expect(warnings.first?.hasPrefix("Me has been digital silence for 30 s: check Microphone permission") == true)
    }

    /// System audio is exact zeros whenever nothing plays, as before the other side
    /// joins, so only a silence while the call plays points at the permission.
    @Test func aSilentThemChannelOnlyBlamesThePermissionIfTheCallIsPlaying() async throws {
        let silentThem = ConversationScript(
            title: "waiting", lines: [.init(speaker: .me, start: 1, end: 3, text: "Are you there?")])
        let setup = try setUp(script: silentThem, seconds: 31, model: nil)
        try await setup.run()
        #expect(
            setup.recorder.warnings == [
                "Them has been digital silence for 30 s. If the call's audio is already playing, check System "
                    + "Audio Recording permission (System Settings > Privacy & Security > Screen & System Audio "
                    + "Recording)."
            ])
    }

    /// The detector only reports speech once it has heard 150 ms of it, so a pause just
    /// under the silence threshold looks, for that long, like one just over it.
    @Test func aPauseJustShortOfTheSilenceKeepsOneTurn() async throws {
        let script = ConversationScript(
            title: "pause",
            lines: [
                .init(speaker: .them, start: 1.0, end: 2.0, text: "Which accounts"),
                .init(speaker: .them, start: 2.65, end: 3.5, text: "were affected?"),
            ])
        let setup = try setUp(script: script, seconds: 5, model: nil)
        try await setup.run()
        #expect(await setup.session.transcript.turns.map(\.text) == ["Which accounts were affected?"])
    }

    /// The user types notes while Them answers. The keys on Me are not speech, so Them's
    /// short pauses do not split the answer, and an "Okay." the recogniser makes up from
    /// the keys is dropped rather than kept as something the user said.
    @Test(arguments: [(6.0, -40.0), (8, -35), (10, -30)])
    func typingWhileThemAnswersIsNotSpeech(keysPerSecond: Double, levelDBFS: Double) async throws {
        let script = ConversationScript(
            title: "typing",
            lines: [
                .init(speaker: .them, start: 1.0, end: 3.0, text: "We saw the fills arrive late,"),
                .init(speaker: .them, start: 3.5, end: 5.5, text: "some by thirty seconds."),
                .init(speaker: .me, start: 5.6, end: 5.9, text: "Okay."),
                .init(speaker: .them, start: 6.0, end: 8.0, text: "Can you tell us why?"),
            ])
        let typing = Synth.keystrokes(seconds: 10, perSecond: keysPerSecond, levelDBFS: levelDBFS)
        let sources = [
            Speaker.me: try ReplaySource(
                audio: WAVAudio(sampleRate: 16_000, channelCount: 1, samples: typing), speaker: .me, pacing: .unpaced),
            .them: try ReplaySource(
                audio: scriptAudio(script, speaker: .them, seconds: 10), speaker: .them, pacing: .unpaced),
        ]
        let session = try setUp(script: script, sources: sources, model: nil).session
        try await session.start()
        await waitForReplay(sources)
        await session.stop()

        let turns = await session.transcript.turns
        #expect(turns.map(\.speaker) == [.them])
        #expect(turns.map(\.text) == ["We saw the fills arrive late, some by thirty seconds. Can you tell us why?"])
    }

    @Test func speechToTextErrorsDoNotEndTheCall() async throws {
        let setup = try setUp(speech: FlakySpeech(script: tradeScript))
        try await setup.run()
        #expect(setup.recorder.lastTranscript?.turns.map(\.text) == tradeScript.lines.map(\.text))
        let warnings = setup.recorder.warnings
        for speaker in Speaker.allCases {
            #expect(warnings.contains { $0.hasPrefix("Speech-to-text for \(speaker.rawValue) dropped") })
            #expect(warnings.contains("Speech-to-text for \(speaker.rawValue) is back."))
        }
    }

    @Test func aNewRequestOrEscapeCancelsTheAnswerInFlight() async throws {
        let model = tradeModel(firstTokenDelay: .milliseconds(20), tokenInterval: .milliseconds(30))
        let setup = try setUp(pacing: .realTime(speed: 1), model: model)
        let session = setup.session
        try await session.start()

        await session.requestAnswer(.quick)
        #expect(await eventually { !setup.recorder.answerText(id: 1).isEmpty })
        await session.requestAnswer(.deep)
        #expect(await eventually { await session.answers.count == 2 })
        await session.requestAnswer(.quick)
        await session.cancelAnswer()
        await setup.stop()

        let answers = await session.answers
        #expect(answers.map(\.id) == [1, 2, 3])
        #expect(answers.map(\.error) == [CallSession.cancelledMessage, nil, CallSession.cancelledMessage])
        #expect(answers[0].text == setup.recorder.answerText(id: 1))
        #expect(answers[1].text == tradeAnswer && answers[1].model == "claude-sonnet-5-5")
        #expect(setup.recorder.failedAnswers.map(\.id) == [1, 3])
        #expect(setup.recorder.all.contains(.answerStarted(id: 2, tier: .deep, model: "claude-sonnet-5-5")))
        #expect(await eventually { model.cancelledCount == 2 })
        #expect(try SessionStore.readAnswers(in: try #require(await session.directory)) == answers)
    }

    @Test func aFailedAnswerKeepsNoText() async throws {
        let setup = try setUp(pacing: .realTime(speed: 1), model: RefusingModel())
        try await setup.session.start()
        await setup.session.requestAnswer(.quick)
        #expect(await eventually { await setup.session.answers.count == 1 })
        await setup.stop()

        #expect(setup.recorder.answerText(id: 1) == "Sure, the account ")
        #expect(setup.recorder.failedAnswers.map(\.message) == ["refused"])
        let answer = try #require(await setup.session.answers.first)
        #expect(answer.text.isEmpty && answer.error == "refused")
        #expect(answer.latency.hotkeyToFirstToken != nil)
    }

    @Test func aDraftMadeWhenThemFinishesIsShownAtOnce() async throws {
        let model = tradeModel(firstTokenDelay: .zero, tokenInterval: .zero)
        let setup = try draftSetUp(model: model)
        try await setup.session.start()
        await waitForReplay(setup.sources)
        // The session has taken in the draft's last event once its usage is costed.
        #expect(await eventually { await setup.session.cost.modelUsage["claude-haiku-5-5"] != nil })

        await setup.session.requestAnswer(.quick)
        await setup.stop()

        #expect(model.requests.count == 2)
        #expect(model.requests[0].userText.contains("Them: Are the fills in?"))
        let answer = try #require(setup.recorder.finishedAnswers.first)
        #expect(answer.fromDraft && answer.text == tradeAnswer)
        #expect(setup.recorder.answerText(id: 1) == tradeAnswer)
        #expect((answer.latency.hotkeyToRequestSent ?? 0) < 0)
        #expect(answer.latency.hotkeyToFirstToken == 0 && answer.latency.hotkeyToDone == 0)
        #expect(answer.latency.endOfSpeechToFirstToken == answer.latency.endOfSpeechToHotkey)
        #expect(answer.cost > 0)
    }

    @Test func aDraftStillStreamingIsShownAndCarriesOn() async throws {
        let model = tradeModel(firstTokenDelay: .milliseconds(100), tokenInterval: .milliseconds(20))
        let setup = try draftSetUp(model: model)
        try await setup.session.start()
        #expect(await eventually { model.requests.count == 1 })

        await setup.session.requestAnswer(.quick)
        #expect(await eventually { await setup.session.answers.count == 1 })
        await setup.stop()

        let answer = try #require(setup.recorder.finishedAnswers.first)
        #expect(answer.fromDraft && answer.text == tradeAnswer)
        #expect(setup.recorder.answerText(id: 1) == tradeAnswer)
        #expect((answer.latency.hotkeyToRequestSent ?? 0) <= 0)
        #expect((answer.latency.hotkeyToFirstToken ?? -1) >= 0)
        #expect((answer.latency.hotkeyToDone ?? 0) > 0)
        #expect(model.requests.count == 2)
    }

    @Test func aDraftIsDroppedOnceSomethingNewIsSaid() async throws {
        let script = ConversationScript(
            title: "draft",
            lines: [
                .init(speaker: .them, start: 0.5, end: 1.5, text: "Are the fills in?"),
                .init(speaker: .me, start: 3.0, end: 3.5, text: "Let me look."),
            ])
        // Me's line is held back until the draft is out: under load Them's turn can
        // otherwise close after it, and a draft that already has it is rightly kept.
        let speech = HeldFinalsSpeech(script: script, holding: [.me])
        let model = tradeModel(firstTokenDelay: .zero, tokenInterval: .zero)
        let setup = try setUp(
            script: script, seconds: 5, pacing: .realTime(speed: 8), speech: speech, model: model
        ) {
            $0.answers.draftAhead = true
        }
        try await setup.session.start()
        #expect(await eventually { model.requests.count == 1 })
        await waitForReplay(setup.sources)
        await speech.releaseFinals()
        #expect(await eventually { await setup.session.transcript.turns.count == 2 })

        await setup.session.requestAnswer(.quick)
        #expect(await eventually { await setup.session.answers.count == 1 })
        await setup.stop()

        let answer = try #require(setup.recorder.finishedAnswers.first)
        #expect(!answer.fromDraft)
        #expect(model.requests.count == 3)
        // The draft may show Me's line as still being said, but not as a turn.
        #expect(!model.requests[0].userText.contains("] Me: Let me look."))
        #expect(model.requests[1].userText.contains("Me: Let me look."))
    }

    @Test func aCallWithDocumentsCachesItsPromptsAtStart() async throws {
        let model = tradeModel(firstTokenDelay: .zero, tokenInterval: .zero)
        let call = CallContext(
            callType: "Work call", documents: [CallContext.Document(name: "runbook.pdf", text: "Restart the bridge.")])
        let setup = try setUp(sources: [.me: FakeSource(.me)], model: model, call: call)
        try await setup.session.start()
        #expect(await eventually { await setup.session.cost.modelUsage.count == 2 })
        await setup.stop()

        let warmUps = model.requests.filter { $0.settings.maxTokens == 1 }
        #expect(warmUps.map(\.settings.model).sorted() == ["claude-haiku-5-5", "claude-sonnet-5-5"])
        #expect(warmUps.allSatisfy { $0.cacheSystem && $0.system.contains("<document name=\"runbook.pdf\">") })
    }

    @Test func aCallWithoutDocumentsSendsNoWarmUps() async throws {
        let model = tradeModel(firstTokenDelay: .zero, tokenInterval: .zero)
        let setup = try setUp(model: model)
        try await setup.run()
        #expect(!model.requests.contains { $0.settings.maxTokens == 1 })
    }

    @Test func aCachedPromptIsRefreshedBeforeItExpires() {
        let now = ContinuousClock.now
        #expect(CallSession.needsCaching(sentAt: nil, now: now))
        #expect(!CallSession.needsCaching(sentAt: now - .seconds(200), now: now))
        #expect(CallSession.needsCaching(sentAt: now - CallSession.cacheRefreshAfter, now: now))
    }

    @Test func aRecapNeverUsesTheDraft() async throws {
        let model = tradeModel(firstTokenDelay: .zero, tokenInterval: .zero)
        let setup = try draftSetUp(model: model)
        try await setup.session.start()
        await waitForReplay(setup.sources)
        #expect(await eventually { model.requests.count == 1 })

        await setup.session.requestAnswer(.recap)
        #expect(await eventually { await setup.session.answers.count == 1 })
        await setup.stop()

        let answer = try #require(setup.recorder.finishedAnswers.first)
        #expect(answer.tier == .recap && !answer.fromDraft && answer.model == AnswerSettings().recap.model)
        #expect(model.requests[1].userText.hasSuffix("Recap the call so far."))
    }

    @Test func aFinalThatArrivesAfterTheHotkeyIsRecordedLate() async throws {
        let script = ConversationScript(
            title: "slow", lines: [.init(speaker: .them, start: 0.5, end: 1.0, text: "Quick question?")])
        let speech = HeldFinalsSpeech(script: script)
        let model = tradeModel()
        let setup = try setUp(script: script, seconds: 3, pacing: .realTime(speed: 4), speech: speech, model: model)
        let session = setup.session
        try await session.start()
        #expect(await eventually { await session.endOfSpeech != nil })
        await session.requestAnswer(.quick)
        #expect(await eventually { await session.answers.count == 1 })
        await speech.releaseFinals()
        #expect(await eventually { await session.transcript.turns.count == 1 })
        await setup.stop()

        let shown = try #require(setup.recorder.finishedAnswers.first)
        #expect(shown.latency.finalToHotkey == nil)
        let speechToHotkey = try #require(shown.latency.endOfSpeechToHotkey)
        #expect(speechToHotkey >= 0 && speechToHotkey < 10_000)

        let saved = try SessionStore.readRecord(in: try #require(await session.directory))
        let late = try #require(saved.answers.first?.latency.finalToHotkey)
        #expect(late < 0)
        // Asked from the interim text, since there was no final yet.
        let request = try #require(model.requests.first)
        #expect(request.userText.contains("Them: Quick question?"))
    }

    @Test func waitingWithADeadlineReportsWhichCameFirst() async {
        #expect(await finishes(within: .seconds(5)) {})
        let slow = await finishes(within: .milliseconds(20)) {
            try? await Task.sleep(for: .seconds(1))
        }
        #expect(!slow)
    }

    @Test func skippingSilenceSendsOnlySpeechAndItsMargins() async throws {
        let script = ConversationScript(
            title: "one line", lines: [.init(speaker: .them, start: 2.0, end: 3.0, text: "Just this.")])
        let setup = try setUp(script: script, seconds: 10, model: nil) { $0.speech.skipSilence = true }
        try await setup.run()
        let seconds = await setup.session.cost.speechSeconds
        #expect((seconds["Them"] ?? 0) > 2.2 && (seconds["Them"] ?? 0) < 2.6)
        #expect((seconds["Me"] ?? 0) == 0)
    }

    /// The lid closed for an hour during a call. Speech-to-text gets a short pause, enough
    /// to finalise what was said before, not an hour of silence to get through first, and
    /// what is said after the wake is still placed an hour into the call.
    @Test func anHourAsleepIsAShortPauseAndKeepsTheCallsTimes() async throws {
        // The scripted recogniser goes by the audio it is sent: two seconds before the
        // sleep, the pause, then the audio after the wake.
        let script = ConversationScript(
            title: "lid closed",
            lines: [
                .init(speaker: .them, start: 0.5, end: 1.8, text: "Before the lid closed."),
                .init(speaker: .them, start: 4.5, end: 5.5, text: "After it opened again."),
            ])
        let them = FeedSource(speaker: .them)
        let session = try setUp(script: script, sources: [.them: them], model: nil).session
        try await session.start()

        them.deliver(Synth.track(seconds: 2, bursts: [0.5...1.8], frequency: 200, amplitude: 0.2), endingAt: 2)
        them.tick(at: 3602)
        #expect(await eventually { await session.transcript.turns.count == 1 })
        them.deliver(Synth.track(seconds: 2, bursts: [0.5...1.5], frequency: 200, amplitude: 0.2), endingAt: 3604)
        #expect(await eventually { await session.transcript.turns.count == 2 })
        await session.stop()

        let turns = await session.transcript.turns
        try #require(turns.map(\.text) == script.lines.map(\.text))
        #expect(abs(turns[0].start - 0.5) < 0.05 && abs(turns[0].end - 1.8) < 0.05)
        #expect(abs(turns[1].start - 3602.5) < 0.05 && abs(turns[1].end - 3603.5) < 0.05)
        #expect(try #require(await session.cost.speechSeconds["Them"]) <= 6.1)
    }

    @Test func withoutALanguageModelThereAreNoAnswersOrSummary() async throws {
        let setup = try setUp(model: nil)
        try await setup.session.start()
        await setup.session.requestAnswer(.quick)
        await waitForReplay(setup.sources)
        await setup.stop()
        #expect(setup.recorder.warnings == ["No language model is configured, so answers are off."])
        #expect(!setup.recorder.all.contains(.summaryStarted))
        let directory = try #require(await setup.session.directory)
        #expect(try SessionStore.readTurns(in: directory).count == 5)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("summary.md").path))
    }

    @Test func savesBothChannelsWhenAsked() async throws {
        let setup = try setUp(model: nil) { $0.storage.saveAudio = true }
        try await setup.run()
        let directory = try #require(await setup.session.directory)
        for name in ["me.wav", "them.wav"] {
            let audio = try WAVReader.read(url: directory.appendingPathComponent(name))
            #expect(audio.sampleRate == 16_000 && audio.samples.count == 176_000, "\(name)")
        }
    }
}
