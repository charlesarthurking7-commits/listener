import Synchronization
import Testing

@testable import ListenerCore

struct RotatingSpeechStreamTests {
    @Test func resultsBecomeEventsAndFinishingSettlesTheRest() async throws {
        let recognizer = FakeRecognizer()
        let stream = try await RotatingSpeechStream.open(recognizer: recognizer)
        let session = try await recognizer.nextSession()

        session.emit(volatileResult(("Hello", 0.1, 0.5)))
        session.onFinish = [finalResult(("Hello there.", 0.1, 0.9))]
        try await send(Synth.tone(seconds: 1.0), to: stream)
        await stream.finish()

        #expect(
            try await stream.events.collect() == [
                SpeechEvent(kind: .interim, text: "Hello", audioStart: 0.1, audioEnd: 0.5),
                SpeechEvent(kind: .final, text: "Hello there.", audioStart: 0.1, audioEnd: 0.9),
            ])
        #expect(session.received.count == AudioChunk.sampleRate)
        #expect(session.finishCalls == 1)
    }

    @Test func aPauseEndsTheSessionAndANewOneCarriesOnTheTimeline() async throws {
        let recognizer = FakeRecognizer()
        let stream = try await RotatingSpeechStream.open(recognizer: recognizer)
        let first = try await recognizer.nextSession()
        first.onFinish = [finalResult(("One.", 0.2, 0.9))]

        // One second of speech, then the fourth 100 ms chunk of silence completes the pause.
        try await send(Synth.tone(seconds: 1.0) + Synth.silence(seconds: 0.4), to: stream)
        let second = try await recognizer.nextSession()
        await stream.waitForReplacement()
        try await send(Synth.tone(seconds: 0.5), to: stream)
        second.emit(finalResult(("Two.", 0.1, 0.4)))
        await stream.finish()

        let events = try await stream.events.collect()
        #expect(events.map(\.kind) == [.final, .final])
        #expect(events.map(\.text) == ["One.", "Two."])
        // The second session started 1.4 s into the channel.
        #expect(near(events.first?.audioStart, 0.2) && near(events.first?.audioEnd, 0.9))
        #expect(near(events.last?.audioStart, 1.5) && near(events.last?.audioEnd, 1.8))
        #expect(first.received.count == seconds(1.4))
        #expect(second.received.count == seconds(0.5))
    }

    @Test func withoutSplittingOneSessionHearsEverythingAcrossPauses() async throws {
        let recognizer = FakeRecognizer()
        let stream = try await RotatingSpeechStream.open(
            recognizer: recognizer, configuration: RotatingSpeechStream.Configuration(splitsAtPauses: false))
        let session = try await recognizer.nextSession()
        session.onFinish = [finalResult(("One. Two.", 0.2, 1.8))]

        let audio = Synth.tone(seconds: 1.0) + Synth.silence(seconds: 0.6) + Synth.tone(seconds: 0.5)
        try await send(audio, to: stream)
        await stream.finish()

        #expect(try await stream.events.collect().map(\.text) == ["One. Two."])
        #expect(session.received.count == audio.count)
        #expect(session.finishCalls == 1)
    }

    @Test func aWordRightAfterThePauseGoesWholeToTheNextSession() async throws {
        let recognizer = FakeRecognizer()
        let stream = try await RotatingSpeechStream.open(recognizer: recognizer)
        let first = try await recognizer.nextSession()
        first.onFinish = [finalResult(("We need to", 0.1, 1.0))]

        // The pause completes at 1.44 s, 40 ms into a chunk, and the next word starts
        // 20 ms later in the same chunk.
        let audio = Synth.tone(seconds: 1.04) + Synth.silence(seconds: 0.42) + Synth.tone(seconds: 0.5)
        try await send(audio, to: stream)
        let second = try await recognizer.nextSession()
        await stream.waitForReplacement()
        second.emit(finalResult(("reconcile.", 0.02, 0.52)))
        await stream.finish()

        #expect(first.received.count == seconds(1.44))
        #expect(first.received.suffix(seconds(0.4)).allSatisfy { $0 == 0 })
        #expect(second.received.elementsEqual(audio[seconds(1.44)...]))
        let events = try await stream.events.collect()
        #expect(events.map(\.text) == ["We need to", "reconcile."])
        #expect(near(events.last?.audioStart, 1.46) && near(events.last?.audioEnd, 1.96))
    }

    /// Starting the next session a little earlier, on the end of the pause, made Apple's
    /// recognizer worse on every fixture call: 59 errors in 494 words with a quarter
    /// second, against 45 with none.
    @Test func theNextSessionHearsNothingOfThePauseBeforeTheCut() async throws {
        let recognizer = FakeRecognizer()
        let stream = try await RotatingSpeechStream.open(recognizer: recognizer)
        _ = try await recognizer.nextSession()

        // The pause completes at 0.9 s; the next words start 0.2 s after that.
        let audio = Synth.tone(seconds: 0.5) + Synth.silence(seconds: 0.6) + Synth.tone(seconds: 0.3)
        try await send(audio, to: stream)
        let second = try await recognizer.nextSession()
        await stream.waitForReplacement()
        second.emit(finalResult(("Two.", 0.2, 0.5)))
        await stream.finish()

        #expect(second.received.elementsEqual(audio[seconds(0.9)...]))
        let last = try await stream.events.collect().last
        #expect(near(last?.audioStart, 1.1) && near(last?.audioEnd, 1.4))
    }

    @Test func theLastWordIsNotRepeatedWhenTheVolatileCopyOfItIsTimedLater() async throws {
        // At Stop the last final has "tomorrow" at 0.8 to 1.0 s, where the volatile
        // result before it, from a shorter context, had it at 1.05 to 1.4 s.
        let recognizer = FakeRecognizer()
        let stream = try await RotatingSpeechStream.open(recognizer: recognizer)
        let session = try await recognizer.nextSession()
        session.emit(
            RecognizerResult(
                isFinal: false, start: 0.2, end: 1.4, finalizedThrough: 0.2,
                pieces: [
                    .init(text: "Speak", start: 0.2, end: 0.5), .init(text: " to", start: 0.5, end: 0.7),
                    .init(text: " you", start: 0.7, end: 0.95), .init(text: " tomorrow", start: 1.05, end: 1.4),
                ]))
        session.onFinish = [
            RecognizerResult(
                isFinal: true, start: 0.2, end: 1.0, finalizedThrough: 2.0,
                pieces: [
                    .init(text: "Speak", start: 0.2, end: 0.5), .init(text: " to", start: 0.5, end: 0.65),
                    .init(text: " you", start: 0.65, end: 0.8), .init(text: " tomorrow.", start: 0.8, end: 1.0),
                ])
        ]
        try await send(Synth.tone(seconds: 2.0), to: stream)
        await stream.finish()

        let finals = try await stream.events.collect().filter { $0.kind == .final }
        #expect(finals.map(\.text) == ["Speak to you tomorrow."])
    }

    @Test func audioThatArrivesWhileASessionEndsIsReplayedIntoTheNextOne() async throws {
        let recognizer = FakeRecognizer()
        let stream = try await RotatingSpeechStream.open(recognizer: recognizer)
        let first = try await recognizer.nextSession()
        first.endsOnFinish = false

        try await send(Synth.tone(seconds: 0.5) + Synth.silence(seconds: 0.4), to: stream)
        try await send(Synth.tone(seconds: 0.3), to: stream)
        #expect(recognizer.startedCount == 1)

        first.end()
        let second = try await recognizer.nextSession()
        await stream.waitForReplacement()
        #expect(second.received == Synth.tone(seconds: 0.3))
        await stream.finish()
    }

    @Test func speechTheRecognizerAlreadySettledDoesNotEndTheSession() async throws {
        let recognizer = FakeRecognizer()
        let stream = try await RotatingSpeechStream.open(recognizer: recognizer)
        let session = try await recognizer.nextSession()
        var events = stream.events.makeAsyncIterator()

        try await send(Synth.tone(seconds: 1.0), to: stream)
        session.emit(finalResult(("Done.", 0.0, 1.0)))
        let settled = try await events.next()
        #expect(settled?.text == "Done.")
        try await send(Synth.silence(seconds: 1.0), to: stream)
        await stream.finish()

        #expect(recognizer.startedCount == 1)
    }

    @Test func aSessionThatStopsByItselfIsReplacedByOneThatHearsWhatItHadNotSettled() async throws {
        let recognizer = FakeRecognizer()
        let stream = try await RotatingSpeechStream.open(recognizer: recognizer)
        let first = try await recognizer.nextSession()
        var events = stream.events.makeAsyncIterator()

        let audio = Synth.tone(seconds: 1.5)
        try await send(audio, to: stream)
        first.emit(finalResult(("We need", 0.0, 0.5)))
        #expect(try await events.next()?.text == "We need")
        first.emit(volatileResult(("to recon", 0.6, 1.2)))
        #expect(try await events.next()?.text == "to recon")
        first.fail(FakeError.recognizerCrashed)
        let second = try await recognizer.nextSession()
        await stream.waitForReplacement()
        second.emit(finalResult(("to reconcile the", 0.1, 0.9)))
        await stream.finish()

        // The old session had settled everything before 0.6 s.
        #expect(second.received.elementsEqual(audio[seconds(0.6)...]))
        var rest: [SpeechEvent] = []
        while let event = try await events.next() {
            rest.append(event)
        }
        // The guess on screen goes rather than becoming final.
        #expect(rest.map(\.kind) == [.interim, .final])
        #expect(rest.map(\.text) == ["", "to reconcile the"])
        #expect(near(rest.last?.audioStart, 0.7) && near(rest.last?.audioEnd, 1.5))
    }

    @Test func repeatedFailuresEndTheStreamWithTheError() async throws {
        let recognizer = FakeRecognizer()
        let stream = try await RotatingSpeechStream.open(recognizer: recognizer)
        for _ in 0..<3 {
            try await recognizer.nextSession().fail(FakeError.recognizerCrashed)
        }

        await #expect(throws: FakeError.recognizerCrashed) {
            _ = try await stream.events.collect()
        }
        await #expect(throws: FakeError.recognizerCrashed) {
            try await stream.send(chunk(Synth.tone(seconds: 0.1)))
        }
    }

    @Test func aRecognizerThatCannotStartFailsTheOpen() async throws {
        let recognizer = FakeRecognizer()
        recognizer.startFailures = 1
        await #expect(throws: FakeError.cannotStart) {
            _ = try await RotatingSpeechStream.open(recognizer: recognizer)
        }
    }

    @Test func aFailedStartDuringReplacementIsRetried() async throws {
        let recognizer = FakeRecognizer()
        let configuration = RotatingSpeechStream.Configuration(retryDelay: .milliseconds(1))
        let stream = try await RotatingSpeechStream.open(recognizer: recognizer, configuration: configuration)
        _ = try await recognizer.nextSession()

        recognizer.startFailures = 2
        try await send(Synth.tone(seconds: 0.5) + Synth.silence(seconds: 0.4), to: stream)
        let replacement = try await recognizer.nextSession()
        await stream.waitForReplacement()
        try await send(Synth.tone(seconds: 0.2), to: stream)
        await stream.finish()

        #expect(replacement.received.count == seconds(0.2))
        #expect(try await stream.events.collect().isEmpty)
    }

    @Test func aSessionThatWillNotFinishIsCancelled() async throws {
        let recognizer = FakeRecognizer()
        let configuration = RotatingSpeechStream.Configuration(finishTimeout: .milliseconds(50))
        let stream = try await RotatingSpeechStream.open(recognizer: recognizer, configuration: configuration)
        let session = try await recognizer.nextSession()
        session.endsOnFinish = false

        session.emit(volatileResult(("Hanging on", 0.0, 0.6)))
        await stream.finish()

        #expect(session.cancelCalls == 1)
        #expect(
            try await stream.events.collect().last
                == SpeechEvent(kind: .final, text: "Hanging on", audioStart: 0, audioEnd: 0.6))
    }

    @Test func aSessionThatIgnoresCancellingIsAbandoned() async throws {
        let recognizer = FakeRecognizer()
        let configuration = RotatingSpeechStream.Configuration(finishTimeout: .milliseconds(20))
        let stream = try await RotatingSpeechStream.open(recognizer: recognizer, configuration: configuration)
        let session = try await recognizer.nextSession()
        session.endsOnFinish = false
        session.endsOnCancel = false

        session.emit(volatileResult(("Wedged", 0.0, 0.4)))
        await stream.finish()
        session.emit(finalResult(("Too late.", 0.0, 0.9)))

        #expect(try await stream.events.collect().map(\.text) == ["Wedged", "Wedged"])
        session.end()
    }

    @Test func audioAfterFinishIsIgnored() async throws {
        let recognizer = FakeRecognizer()
        let stream = try await RotatingSpeechStream.open(recognizer: recognizer)
        let session = try await recognizer.nextSession()
        await stream.finish()
        try await stream.send(chunk(Synth.tone(seconds: 0.1)))
        await stream.finish()
        #expect(session.received.isEmpty)
        #expect(session.finishCalls == 1)
    }
}

private enum FakeError: Error {
    case cannotStart
    case recognizerCrashed
    case noSession
}

/// Hands out sessions the test drives by hand.
private final class FakeRecognizer: SessionRecognizer {
    private let failures = Mutex(0)
    private let started: AsyncStream<FakeSession>
    private let startedContinuation: AsyncStream<FakeSession>.Continuation
    private let count = Mutex(0)

    init() {
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    var startFailures: Int {
        get { failures.withLock { $0 } }
        set { failures.withLock { $0 = newValue } }
    }

    var startedCount: Int {
        count.withLock { $0 }
    }

    func startSession() async throws -> any RecognizerSession {
        let fails = failures.withLock { remaining in
            defer { remaining = max(remaining - 1, 0) }
            return remaining > 0
        }
        if fails {
            throw FakeError.cannotStart
        }
        let session = FakeSession()
        count.withLock { $0 += 1 }
        startedContinuation.yield(session)
        return session
    }

    /// The next session the stream starts, in order.
    func nextSession() async throws -> FakeSession {
        for await session in started {
            return session
        }
        throw FakeError.noSession
    }
}

private final class FakeSession: RecognizerSession {
    private struct State {
        var received: [Int16] = []
        var finishCalls = 0
        var cancelCalls = 0
        var onFinish: [RecognizerResult] = []
        var endsOnFinish = true
        var endsOnCancel = true
    }

    let results: AsyncThrowingStream<RecognizerResult, any Error>
    private let output: AsyncThrowingStream<RecognizerResult, any Error>.Continuation
    private let state = Mutex(State())

    init() {
        (results, output) = AsyncThrowingStream.makeStream()
    }

    var received: [Int16] { state.withLock { $0.received } }
    var finishCalls: Int { state.withLock { $0.finishCalls } }
    var cancelCalls: Int { state.withLock { $0.cancelCalls } }

    var onFinish: [RecognizerResult] {
        get { state.withLock { $0.onFinish } }
        set { state.withLock { $0.onFinish = newValue } }
    }

    var endsOnFinish: Bool {
        get { state.withLock { $0.endsOnFinish } }
        set { state.withLock { $0.endsOnFinish = newValue } }
    }

    var endsOnCancel: Bool {
        get { state.withLock { $0.endsOnCancel } }
        set { state.withLock { $0.endsOnCancel = newValue } }
    }

    func emit(_ result: RecognizerResult) {
        output.yield(result)
    }

    func fail(_ error: any Error) {
        output.finish(throwing: error)
    }

    func end() {
        output.finish()
    }

    func send(_ samples: [Int16]) throws {
        state.withLock { $0.received += samples }
    }

    func finish() async {
        let (finals, ends) = state.withLock { state in
            state.finishCalls += 1
            return (state.onFinish, state.endsOnFinish)
        }
        for result in finals {
            output.yield(result)
        }
        if ends {
            output.finish()
        }
    }

    func cancel() async {
        let ends = state.withLock { state in
            state.cancelCalls += 1
            return state.endsOnCancel
        }
        if ends {
            output.finish()
        }
    }
}

private func seconds(_ value: Double) -> Int {
    Int((value * Double(AudioChunk.sampleRate)).rounded())
}

private func chunk(_ samples: [Int16]) -> AudioChunk {
    AudioChunk(speaker: .them, samples: samples, capturedAt: .now)
}

/// Sends audio the way capture does, in 100 ms chunks.
private func send(_ samples: [Int16], to stream: RotatingSpeechStream) async throws {
    let size = AudioChunk.sampleRate / 10
    for start in stride(from: 0, to: samples.count, by: size) {
        try await stream.send(chunk(Array(samples[start..<min(start + size, samples.count)])))
    }
}
