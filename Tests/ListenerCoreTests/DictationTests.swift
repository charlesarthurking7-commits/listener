import Foundation
import Synchronization
import Testing

@testable import ListenerCore

struct DictationTidierTests {
    private let outlook = DictationTarget(
        appName: "Microsoft Outlook", bundleID: "com.microsoft.Outlook", windowTitle: "Re: FIX drops")

    private func tidier(_ model: (any LanguageModelProvider)?, tidy: Bool = true, vocabulary: [String] = [])
        -> DictationTidier
    {
        var settings = DictationSettings()
        settings.tidy = tidy
        settings.vocabulary = vocabulary
        return DictationTidier(model: model, settings: settings, aboutMe: "I'm Charlie.")
    }

    @Test func typesWhatTheModelWrote() async {
        let model = ScriptedLanguageModel(answer: "Hi Sam,\n\nThanks for that.\n")
        let result = await tidier(model).tidy("hi sam um thanks for that", for: outlook)
        #expect(result == DictationTidier.Result(text: "Hi Sam,\n\nThanks for that.", usage: result.usage))
        #expect(result.usage != nil)
    }

    @Test func theRequestCarriesTheTargetVocabularyAndSpeaker() async throws {
        let model = ScriptedLanguageModel(answer: "OK.")
        _ = await tidier(model, vocabulary: ["Pelican", " ", "MT5"]).tidy("ok", for: outlook)
        let request = try #require(model.requests.first)
        #expect(request.settings == DictationSettings().model)
        #expect(request.userText.contains("<target>\nApp: Microsoft Outlook\nWindow: Re: FIX drops\n</target>"))
        #expect(request.userText.hasSuffix("<transcript>\nok\n</transcript>"))
        #expect(request.system.contains("spell it exactly like this: Pelican, MT5."))
        #expect(request.system.contains("<about_speaker>\nI'm Charlie.\n</about_speaker>"))
    }

    @Test func leavesOutWhatItDoesNotKnow() {
        let request = DictationTidier.request(
            heard: "ok", target: DictationTarget(), settings: DictationSettings(), aboutMe: " ")
        #expect(request.userText == "<transcript>\nok\n</transcript>")
        #expect(!request.system.contains("about_speaker"))
        #expect(!request.system.contains("spell it exactly"))
    }

    @Test func aLongWindowTitleIsCut() {
        let section = DictationTidier.targetSection(DictationTarget(windowTitle: String(repeating: "a", count: 500)))
        #expect(section.count < DictationTidier.maxTitleCharacters + 40)
    }

    @Test func nothingHeardTypesNothingWithoutAskingClaude() async {
        let model = ScriptedLanguageModel(answer: "unused")
        #expect(await tidier(model).tidy("  \n", for: outlook) == DictationTidier.Result(text: ""))
        #expect(model.requests.isEmpty)
    }

    @Test func theNothingReplyTypesNothing() async {
        let model = ScriptedLanguageModel(answer: DictationTidier.nothingReply)
        #expect(await tidier(model).tidy("um uh", for: outlook).text == "")
    }

    @Test func withTidyingOffTypesWhatWasHeard() async {
        let model = ScriptedLanguageModel(answer: "unused")
        #expect(
            await tidier(model, tidy: false).tidy(" um hello ", for: outlook)
                == DictationTidier.Result(text: "um hello"))
        #expect(model.requests.isEmpty)
    }

    @Test func withoutAKeyTypesWhatWasHeardAndSaysWhy() async {
        let result = await tidier(nil).tidy("um hello", for: outlook)
        #expect(result.text == "um hello")
        #expect(result.problem != nil)
    }

    @Test func aFailedRequestTypesWhatWasHeard() async {
        struct Offline: Error {}
        let model = ScriptedLanguageModel { _ in throw Offline() }
        let result = await tidier(model).tidy("um hello", for: outlook)
        #expect(result.text == "um hello")
        #expect(result.problem != nil)
    }

    @Test func aSlowRequestTypesWhatWasHeard() async {
        let model = ScriptedLanguageModel(answer: "Hello.", firstTokenDelay: .seconds(5))
        let result = await tidier(model).tidy("um hello", for: outlook, within: .milliseconds(50))
        #expect(result == DictationTidier.Result(text: "um hello", problem: DictationTidierError.tooSlow.description))
    }

    @Test func aReplyCutShortTypesWhatWasHeard() async {
        let model = ScriptedLanguageModel(answer: "Hello", stopReason: "max_tokens")
        let result = await tidier(model).tidy("um hello there", for: outlook)
        #expect(result.text == "um hello there")
        #expect(result.problem == DictationTidierError.cutShort.description)
    }

    @Test func aReplyFarLongerThanTheDictationIsAnAnswerNotATidiedCopy() {
        let heard = "what time does the London session open"
        let answer = "The London session opens at 8am UK time, which is 7am UTC in summer and 8am UTC in winter."
        #expect(DictationTidier.typed(answer, heard: heard) == nil)
        #expect(DictationTidier.typed("What time does the London session open?", heard: heard) != nil)
    }

    @Test func aReplyWrappedInTheTranscriptTagsIsUnwrapped() {
        #expect(DictationTidier.typed("<transcript>\nHello.\n</transcript>", heard: "hello") == "Hello.")
        #expect(DictationTidier.typed("<text>Hello.</text>", heard: "hello") == "Hello.")
    }

    @Test func theTextAroundTheCursorGoesWithTheRequest() async throws {
        let model = ScriptedLanguageModel(answer: "the fills from Tuesday")
        let target = DictationTarget(
            appName: "Notes", textBeforeCursor: "Please check ", textAfterCursor: " before the call.")
        let result = await tidier(model).tidy("the fills from tuesday", for: target)
        let request = try #require(model.requests.first)
        #expect(request.userText.contains("<before_cursor>Please check </before_cursor>"))
        #expect(request.userText.contains("<after_cursor> before the call.</after_cursor>"))
        #expect(result.text == "the fills from Tuesday")
    }

    @Test func textIsSpacedAgainstTheWordsEitherSideOfTheCursor() {
        func fitted(_ text: String, _ before: String?, _ after: String?) -> String {
            DictationTidier.fitted(text, into: DictationTarget(textBeforeCursor: before, textAfterCursor: after))
        }
        #expect(fitted("the fills", "Please check", "before the call") == " the fills ")
        #expect(fitted("the fills", "Please check ", " before") == "the fills")
        #expect(fitted("fills", "(", ")") == "fills")
        #expect(fitted("Hello.", nil, nil) == "Hello.")
        #expect(fitted("Hello.", "", "") == "Hello.")
        #expect(fitted("", "word", "word") == "")
    }

    @Test func theTimeLimitGrowsWithTheDictation() {
        #expect(
            DictationTidier.timeLimit(for: "one two")
                < DictationTidier.timeLimit(for: String(repeating: "word ", count: 300)))
    }
}

struct DictationRecorderTests {
    @Test func audioFromBeforeTheRecognizerIsReadyIsHeard() async throws {
        let recorder = DictationRecorder(
            source: StartingSource(chunks: 3), speech: CountingSpeech(openDelay: .milliseconds(100)))
        let levels = Collected<Double>()
        _ = try await recorder.start { levels.add($0) }
        let heard = await recorder.finish()
        #expect(heard == DictationRecorder.Heard(text: "chunk1 chunk2 chunk3"))
        #expect(levels.all.count == 3)
    }

    @Test func aRecognizerThatFailsKeepsWhatItHeardAndSaysWhy() async throws {
        let source = PushSource(speaker: .me, samples: Array(repeating: 100, count: AudioChunk.sampleRate))
        let recorder = DictationRecorder(source: source, speech: CountingSpeech(failAfter: 2))
        _ = try await recorder.start { _ in }
        source.play(until: 0.5)
        let heard = await recorder.finish()
        #expect(heard.text == "chunk1 chunk2")
        #expect(heard.problem != nil)
    }

    @Test func aRecognizerThatCannotOpenStopsTheMicrophone() async throws {
        let source = FakeSource(.me)
        let recorder = DictationRecorder(source: source, speech: CountingSpeech(opens: false))
        await #expect(throws: CountingSpeech.Failure.self) {
            _ = try await recorder.start { _ in }
        }
        #expect(source.stops == 1)
    }
}

struct FallbackSpeechToTextTests {
    @Test func usesThePrimaryWhenItOpens() async throws {
        let fallbacks = Collected<String>()
        let speech = FallbackSpeechToText(primary: CountingSpeech(), fallback: CountingSpeech(opens: false)) {
            fallbacks.add(ErrorText.describe($0))
        }
        _ = try await speech.openStream(for: .me)
        #expect(fallbacks.all.isEmpty)
    }

    @Test func usesTheFallbackWhenThePrimaryCannotOpenAndSaysWhy() async throws {
        let fallbacks = Collected<String>()
        let speech = FallbackSpeechToText(primary: CountingSpeech(opens: false), fallback: CountingSpeech()) {
            fallbacks.add(ErrorText.describe($0))
        }
        let stream = try await speech.openStream(for: .me)
        try await stream.send(AudioChunk(speaker: .me, samples: [1], capturedAt: .now))
        await stream.finish()
        #expect(try await stream.events.collect().map(\.text) == ["chu", "chunk1"])
        #expect(fallbacks.all.count == 1)
    }
}

/// A microphone whose first audio arrives as it starts, before the recognizer is open.
private final class StartingSource: AudioCaptureSource, Sendable {
    let chunks: Int

    init(chunks: Int) {
        self.chunks = chunks
    }

    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo {
        for _ in 0..<chunks {
            onChunk(AudioChunk(speaker: .me, samples: Array(repeating: 100, count: 1600), capturedAt: .now))
        }
        return ChannelInfo(speaker: .me, backend: "test", device: "test", nativeFormat: "16 kHz")
    }

    func stop() {}
}

/// Recognises each chunk as one word, "chunk1", "chunk2" and so on.
private struct CountingSpeech: SpeechToTextProvider {
    struct Failure: Error {}

    var openDelay: Duration = .zero
    var opens = true
    var failAfter: Int?
    let displayName = "counting"

    func openStream(for speaker: Speaker) async throws -> any SpeechStream {
        try await Task.sleep(for: openDelay)
        guard opens else {
            throw Failure()
        }
        return CountingStream(failAfter: failAfter)
    }
}

private final class CountingStream: SpeechStream, Sendable {
    let events: AsyncThrowingStream<SpeechEvent, any Error>
    private let output: AsyncThrowingStream<SpeechEvent, any Error>.Continuation
    private let failAfter: Int?
    private let count = Mutex(0)

    init(failAfter: Int?) {
        (events, output) = AsyncThrowingStream<SpeechEvent, any Error>.makeStream()
        self.failAfter = failAfter
    }

    func send(_ chunk: AudioChunk) async throws {
        let count = count.withLock { count in
            count += 1
            return count
        }
        if let failAfter, count > failAfter {
            output.finish(throwing: CountingSpeech.Failure())
            throw CountingSpeech.Failure()
        }
        output.yield(SpeechEvent(kind: .interim, text: "chu"))
        output.yield(SpeechEvent(kind: .final, text: "chunk\(count)"))
    }

    func finish() async {
        output.finish()
    }
}
