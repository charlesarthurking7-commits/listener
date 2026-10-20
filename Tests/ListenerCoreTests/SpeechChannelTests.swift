import Foundation
import Synchronization
import Testing

@testable import ListenerCore

/// Speech-to-text whose streams follow a per-stream plan, recording what they receive.
final class PlannedSpeech: SpeechToTextProvider, Sendable {
    struct Plan: Sendable {
        var failToOpen = false
        /// Throw on this send (1-based).
        var failOnSend: Int?
        /// End the events, without an error, after this send.
        var endAfterSend: Int?
        /// Events to emit after a send, given the send count.
        var respond: @Sendable (Int) -> [SpeechEvent] = { _ in [] }
        var onFinish: [SpeechEvent] = []
        /// Never end the events, even after finish().
        var hangOnFinish = false
    }

    struct OpenFailure: Error {}

    private let plans: [Plan]
    private let state = Mutex<(opens: Int, streams: [PlannedStream])>((0, []))

    init(_ plans: [Plan]) {
        self.plans = plans
    }

    var displayName: String { "Planned" }
    var streams: [PlannedStream] { state.withLock { $0.streams } }

    func openStream(for speaker: Speaker) async throws -> any SpeechStream {
        let plan = state.withLock { state in
            state.opens += 1
            return plans[min(state.opens, plans.count) - 1]
        }
        if plan.failToOpen {
            throw OpenFailure()
        }
        let stream = PlannedStream(plan)
        state.withLock { $0.streams.append(stream) }
        return stream
    }
}

actor PlannedStream: SpeechStream {
    struct SendFailure: Error {}

    nonisolated let events: AsyncThrowingStream<SpeechEvent, any Error>
    private let continuation: AsyncThrowingStream<SpeechEvent, any Error>.Continuation
    private let plan: PlannedSpeech.Plan
    private(set) var received: [AudioChunk] = []
    private var sends = 0

    init(_ plan: PlannedSpeech.Plan) {
        (events, continuation) = AsyncThrowingStream.makeStream(of: SpeechEvent.self)
        self.plan = plan
    }

    /// The first sample of each chunk received, which the tests use to tell frames apart.
    var frameMarks: [Int16] { received.map { $0.samples.first ?? -1 } }

    func send(_ chunk: AudioChunk) async throws {
        sends += 1
        if sends == plan.failOnSend {
            throw SendFailure()
        }
        received.append(chunk)
        for event in plan.respond(sends) {
            continuation.yield(event)
        }
        if sends == plan.endAfterSend {
            continuation.finish()
        }
    }

    func finish() async {
        for event in plan.onFinish {
            continuation.yield(event)
        }
        if !plan.hangOnFinish {
            continuation.finish()
        }
    }
}

final class OutputLog: Sendable {
    private let outputs = Mutex<[SpeechChannel.Output]>([])

    func add(_ output: SpeechChannel.Output) {
        outputs.withLock { $0.append(output) }
    }

    var events: [SpeechEvent] {
        outputs.withLock { $0 }.compactMap { output in
            if case .event(let event) = output { return event }
            return nil
        }
    }

    var warnings: [String] {
        outputs.withLock { $0 }.compactMap { output in
            if case .warning(let message) = output { return message }
            return nil
        }
    }
}

struct SpeechChannelTests {
    private let fastRetry = SpeechChannel.RetryPolicy(
        initialDelay: .milliseconds(10), maximumDelay: .milliseconds(40), drainTimeout: .milliseconds(50))

    /// A 100 ms frame starting at `start` on the channel, its samples all `mark`.
    private func frame(_ mark: Int16, at start: Double) -> ChannelFrame {
        ChannelFrame(
            chunk: AudioChunk(speaker: .them, samples: [Int16](repeating: mark, count: 1_600), capturedAt: .now),
            start: start)
    }

    private func channel(_ provider: PlannedSpeech, log: OutputLog) -> SpeechChannel {
        SpeechChannel(speaker: .them, provider: provider, retry: fastRetry) { log.add($0) }
    }

    @Test func resultTimesComeBackOnTheChannelsTimeline() async throws {
        let final = SpeechEvent(kind: .final, text: "words", audioStart: 0.25, audioEnd: 0.35)
        let provider = PlannedSpeech([PlannedSpeech.Plan(respond: { $0 == 5 ? [final] : [] })])
        let log = OutputLog()
        let speech = channel(provider, log: log)
        // Silence was skipped between 0.3 s and 5.0 s of the channel.
        for (mark, start) in zip(Int16(0)..., [0, 0.1, 0.2, 5.0, 5.1]) {
            speech.send(frame(mark, at: start))
        }
        speech.finish()
        await speech.waitUntilDone()

        let converted = try #require(log.events.first)
        #expect(converted.text == "words")
        #expect(abs((converted.audioStart ?? 0) - 0.25) < 1e-9)
        #expect(abs((converted.audioEnd ?? 0) - 5.05) < 1e-9)
        #expect(log.warnings.isEmpty)
    }

    /// Where skipped silence was cut out, the end of the speech before the cut and the
    /// start of the speech after it are the same point of the stream's audio.
    @Test func timesAtASkippedGapMapToTheSpeechTheyBelongTo() async throws {
        let before = SpeechEvent(kind: .final, text: "before", audioStart: 0, audioEnd: 0.3)
        let after = SpeechEvent(kind: .final, text: "after", audioStart: 0.3, audioEnd: 0.5)
        let provider = PlannedSpeech([PlannedSpeech.Plan(respond: { [3: [before], 5: [after]][$0] ?? [] })])
        let log = OutputLog()
        let speech = channel(provider, log: log)
        for (mark, start) in zip(Int16(0)..., [0, 0.1, 0.2, 5.0, 5.1]) {
            speech.send(frame(mark, at: start))
        }
        speech.finish()
        await speech.waitUntilDone()

        let times = log.events.map { [$0.audioStart ?? -1, $0.audioEnd ?? -1] }
        #expect(times.count == 2)
        for (time, expected) in zip(times.joined(), [0, 0.3, 5.0, 5.2]) {
            #expect(abs(time - expected) < 1e-9)
        }
    }

    @Test func aFailedSendReconnectsAndResendsAudioSinceTheLastFinal() async throws {
        let firstFinal = SpeechEvent(kind: .final, text: "one", audioStart: 0, audioEnd: 0.2)
        let secondFinal = SpeechEvent(kind: .final, text: "two", audioStart: 0, audioEnd: 0.4)
        let provider = PlannedSpeech([
            PlannedSpeech.Plan(failOnSend: 4, respond: { $0 == 2 ? [firstFinal] : [] }),
            PlannedSpeech.Plan(onFinish: [secondFinal]),
        ])
        let log = OutputLog()
        let speech = channel(provider, log: log)
        for mark in Int16(0)..<6 {
            speech.send(frame(mark, at: Double(mark) / 10))
        }
        speech.finish()
        await speech.waitUntilDone()

        let streams = provider.streams
        #expect(streams.count == 2)
        #expect(await streams[0].frameMarks == [0, 1, 2])
        // Frames 0 and 1 were finalised; 2 and 3 were not, so they go to the new stream first.
        #expect(await streams[1].frameMarks == [2, 3, 4, 5])
        // The old stream's queued final still counts, after the interim text is cleared.
        #expect(log.events.map(\.text) == ["", "one", "two"])
        #expect(
            log.events.last.map { abs(($0.audioStart ?? 0) - 0.2) < 1e-9 && abs(($0.audioEnd ?? 0) - 0.6) < 1e-9 }
                == true)
        #expect(log.warnings.count == 2)
        #expect(log.warnings.first?.hasPrefix("Speech-to-text for Them dropped") == true)
        #expect(log.warnings.last == "Speech-to-text for Them is back.")
    }

    @Test func aStreamThatCannotOpenIsRetried() async throws {
        let provider = PlannedSpeech([
            PlannedSpeech.Plan(failToOpen: true),
            PlannedSpeech.Plan(failToOpen: true),
            PlannedSpeech.Plan(),
        ])
        let log = OutputLog()
        let speech = channel(provider, log: log)
        for mark in Int16(0)..<3 {
            speech.send(frame(mark, at: Double(mark) / 10))
        }
        #expect(await eventually { provider.streams.count == 1 })
        speech.finish()
        await speech.waitUntilDone()
        #expect(await provider.streams[0].frameMarks == [0, 1, 2])
        #expect(log.warnings.count == 2)
    }

    @Test func aStreamEndingByItselfIsReopened() async throws {
        let provider = PlannedSpeech([PlannedSpeech.Plan(endAfterSend: 1), PlannedSpeech.Plan()])
        let log = OutputLog()
        let speech = channel(provider, log: log)
        speech.send(frame(0, at: 0))
        #expect(await eventually { provider.streams.count == 2 })
        speech.send(frame(1, at: 0.1))
        speech.finish()
        await speech.waitUntilDone()
        #expect(await provider.streams[1].frameMarks == [0, 1])
        #expect(log.warnings.first?.contains("ended unexpectedly") == true)
    }

    @Test func endOfAudioWithoutAStreamTriesOnceMore() async throws {
        let provider = PlannedSpeech([
            PlannedSpeech.Plan(failToOpen: true),
            PlannedSpeech.Plan(onFinish: [SpeechEvent(kind: .final, text: "late", audioStart: 0, audioEnd: 0.1)]),
        ])
        let log = OutputLog()
        let speech = SpeechChannel(
            speaker: .them, provider: provider,
            retry: .init(initialDelay: .seconds(60), maximumDelay: .seconds(60))
        ) { log.add($0) }
        speech.send(frame(7, at: 0))
        speech.finish()
        await speech.waitUntilDone()
        #expect(log.events.map(\.text) == ["", "late"])
    }

    @Test func aFailedStreamThatNeverEndsIsGivenUpAfterTheDrainTimeout() async throws {
        let provider = PlannedSpeech([
            PlannedSpeech.Plan(failOnSend: 2, hangOnFinish: true),
            PlannedSpeech.Plan(),
        ])
        let log = OutputLog()
        let speech = channel(provider, log: log)
        for mark in Int16(0)..<3 {
            speech.send(frame(mark, at: Double(mark) / 10))
        }
        #expect(await eventually { provider.streams.count == 2 })
        speech.finish()
        await speech.waitUntilDone()
        #expect(await provider.streams[1].frameMarks == [0, 1, 2])
    }

    @Test func cancelEndsAChannelWhoseStreamNeverFinishes() async {
        let provider = PlannedSpeech([PlannedSpeech.Plan(hangOnFinish: true)])
        let speech = channel(provider, log: OutputLog())
        speech.send(frame(0, at: 0))
        speech.finish()
        let finished = await finishes(within: .milliseconds(200)) { await speech.waitUntilDone() }
        #expect(!finished)
        speech.cancel()
        await speech.waitUntilDone()
    }
}
