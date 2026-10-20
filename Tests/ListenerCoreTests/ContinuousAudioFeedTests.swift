import Synchronization
import Testing

@testable import ListenerCore

struct ContinuousAudioFeedTests {
    private final class Collector: Sendable {
        private let chunks = Mutex<[AudioChunk]>([])

        func append(_ chunk: AudioChunk) {
            chunks.withLock { $0.append(chunk) }
        }

        var all: [AudioChunk] {
            chunks.withLock { $0 }
        }

        var sampleCount: Int {
            all.reduce(0) { $0 + $1.samples.count }
        }
    }

    private func audio(_ milliseconds: Int, endingAt end: ContinuousClock.Instant) -> AudioChunk {
        AudioChunk(
            speaker: .them, samples: Array(repeating: 7, count: AudioChunk.sampleRate * milliseconds / 1000),
            capturedAt: end)
    }

    /// A tick far in the future keeps the background timer out of the way of these tests.
    private func makeFeed(_ collector: Collector) -> ContinuousAudioFeed {
        ContinuousAudioFeed(speaker: .them, tickInterval: .seconds(3600)) { collector.append($0) }
    }

    @Test func ignoresAudioBeforeStart() {
        let collector = Collector()
        let feed = makeFeed(collector)
        feed.accept(audio(100, endingAt: .now))
        #expect(collector.all.isEmpty)
        feed.stop()
    }

    @Test func passesAudioThroughInOrderAndFillsGaps() {
        let collector = Collector()
        let feed = makeFeed(collector)
        let origin = ContinuousClock.now
        feed.start(at: origin)

        feed.accept(audio(100, endingAt: origin + .milliseconds(100)))
        feed.tick(now: origin + .milliseconds(1000))
        feed.accept(audio(100, endingAt: origin + .milliseconds(1200)))

        let chunks = collector.all
        #expect(collector.sampleCount == 16_000 * 12 / 10)
        #expect(chunks.first?.samples.first == 7)
        #expect(chunks.last?.samples.first == 7)
        #expect(zip(chunks, chunks.dropFirst()).allSatisfy { $0.capturedAt <= $1.capturedAt })
        feed.stop()
    }

    @Test func deliversNothingAfterStop() {
        let collector = Collector()
        let feed = makeFeed(collector)
        let origin = ContinuousClock.now
        feed.start(at: origin)
        feed.stop()

        feed.accept(audio(100, endingAt: origin + .milliseconds(100)))
        feed.tick(now: origin + .seconds(5))
        #expect(collector.all.isEmpty)
    }

    @Test func startAfterStopDoesNothing() {
        let collector = Collector()
        let feed = makeFeed(collector)
        feed.stop()
        feed.start()
        feed.tick(now: .now + .seconds(5))
        #expect(collector.all.isEmpty)
    }

    @Test func backgroundTickFillsSilenceWhenTheSourceGoesQuiet() async throws {
        let collector = Collector()
        let feed = ContinuousAudioFeed(speaker: .me, threshold: .milliseconds(20), tickInterval: .milliseconds(10)) {
            collector.append($0)
        }
        feed.start()

        let deadline = ContinuousClock.now + .seconds(10)
        while collector.all.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        feed.stop()

        let chunks = collector.all
        #expect(!chunks.isEmpty)
        #expect(chunks.allSatisfy { $0.speaker == .me && LevelMeter.isDigitalSilence($0.samples) })
    }
}
