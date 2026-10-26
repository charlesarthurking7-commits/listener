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

    @Test func aSessionThatStopsByItselfIsReplaced() async throws {
        let recognizer = FakeRecognizer()
        let stream = try await RotatingSpeechStream.open(recognizer: recognizer)
        let first = try await recognizer.nextSession()

        first.emit(volatileResult(("Still", 0.0, 0.3)))
        first.fail(FakeError.recognizerCrashed)
        let second = try await recognizer.nextSession()
        await stream.waitForReplacement()
        second.emit(finalResult(("going.", 0.0, 0.4)))
        await stream.finish()

        #expect(try await stream.events.collect().filter { $0.kind == .final }.map(\.text) == ["Still", "going."])
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
