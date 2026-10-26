import Testing

@testable import ListenerCore

struct ContinuousAudioFeedTests {
    private func audio(_ milliseconds: Int, endingAt end: ContinuousClock.Instant) -> AudioChunk {
        AudioChunk(
            speaker: .them, samples: Array(repeating: 7, count: AudioChunk.sampleRate * milliseconds / 1000),
            capturedAt: end)
    }

    /// A tick far in the future keeps the background timer out of the way of these tests.
    private func makeFeed(_ collector: Collected<AudioChunk>) -> ContinuousAudioFeed {
        ContinuousAudioFeed(speaker: .them, tickInterval: .seconds(3600)) { collector.add($0) }
    }

    @Test func ignoresAudioBeforeStart() {
        let collector = Collected<AudioChunk>()
        let feed = makeFeed(collector)
        feed.accept(audio(100, endingAt: .now))
        #expect(collector.all.isEmpty)
        feed.stop()
    }

    @Test func passesAudioThroughInOrderAndFillsGaps() {
        let collector = Collected<AudioChunk>()
        let feed = makeFeed(collector)
        let origin = ContinuousClock.now
        feed.start(at: origin)

        feed.accept(audio(100, endingAt: origin + .milliseconds(100)))
        feed.tick(now: origin + .milliseconds(1000))
        feed.accept(audio(100, endingAt: origin + .milliseconds(1200)))

        let chunks = collector.all
        #expect(collector.samples.count == 16_000 * 12 / 10)
        #expect(chunks.first?.samples.first == 7)
        #expect(chunks.last?.samples.first == 7)
        #expect(zip(chunks, chunks.dropFirst()).allSatisfy { $0.capturedAt <= $1.capturedAt })
        feed.stop()
    }

    /// The lid closed for an hour with a call running. Whichever comes first after the
    /// wake, the tick or the source's next buffer (on the tap's IO thread), the channel
    /// gets a short pause rather than an hour of silence in one go.
    @Test(arguments: [true, false])
    func anHourAsleepBecomesAShortPause(tickFirst: Bool) {
        let collector = Collected<AudioChunk>()
        let feed = makeFeed(collector)
        let origin = ContinuousClock.now
        feed.start(at: origin)

        feed.accept(audio(100, endingAt: origin + .milliseconds(100)))
        let woke = origin + .seconds(3600)
        if tickFirst {
            feed.tick(now: woke)
        }
        feed.accept(audio(100, endingAt: woke + .milliseconds(100)))

        let chunks = collector.all
        #expect(collector.samples.count == 1_600 + SampleClock.samples(in: GapFiller.maximumFill) + 1_600)
        #expect(chunks.last?.samples.first == 7)
        #expect(chunks.last?.capturedAt == woke + .milliseconds(100))
        #expect(zip(chunks, chunks.dropFirst()).allSatisfy { $0.capturedAt <= $1.capturedAt })
        feed.stop()
    }

    @Test func deliversNothingAfterStop() {
        let collector = Collected<AudioChunk>()
        let feed = makeFeed(collector)
        let origin = ContinuousClock.now
        feed.start(at: origin)
        feed.stop()

        feed.accept(audio(100, endingAt: origin + .milliseconds(100)))
        feed.tick(now: origin + .seconds(5))
        #expect(collector.all.isEmpty)
    }

    @Test func startAfterStopDoesNothing() {
        let collector = Collected<AudioChunk>()
        let feed = makeFeed(collector)
        feed.stop()
        feed.start()
        feed.tick(now: .now + .seconds(5))
        #expect(collector.all.isEmpty)
    }

    @Test func backgroundTickFillsSilenceWhenTheSourceGoesQuiet() async throws {
        let collector = Collected<AudioChunk>()
        let feed = ContinuousAudioFeed(speaker: .me, threshold: .milliseconds(20), tickInterval: .milliseconds(10)) {
            collector.add($0)
        }
        feed.start()

        await eventually { !collector.all.isEmpty }
        feed.stop()

        let chunks = collector.all
        #expect(!chunks.isEmpty)
        #expect(chunks.allSatisfy { $0.speaker == .me && LevelMeter.isDigitalSilence($0.samples) })
    }
}
