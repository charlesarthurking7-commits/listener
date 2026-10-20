import Testing

@testable import ListenerCore

struct GapFillerTests {
    private let origin = ContinuousClock.now

    /// A chunk of `milliseconds` of non-zero audio that finished arriving at `endMs` after origin.
    private func chunk(endMs: Int, milliseconds: Int = 100) -> AudioChunk {
        let count = AudioChunk.sampleRate * milliseconds / 1000
        return AudioChunk(
            speaker: .them, samples: Array(repeating: 100, count: count), capturedAt: origin + .milliseconds(endMs))
    }

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        origin + .milliseconds(milliseconds)
    }

    private func sampleCount(_ chunks: [AudioChunk]) -> Int {
        chunks.reduce(0) { $0 + $1.samples.count }
    }

    @Test func continuousAudioPassesThroughUntouched() {
        var filler = GapFiller(speaker: .them, origin: origin)
        for end in stride(from: 100, through: 1000, by: 100) {
            let output = filler.accept(chunk(endMs: end))
            #expect(output.count == 1)
            #expect(!LevelMeter.isDigitalSilence(output[0].samples))
        }
        #expect(filler.streamEnd == at(1000))
    }

    @Test func jitterBelowTheThresholdIsLeftAlone() {
        var filler = GapFiller(speaker: .them, origin: origin, threshold: .milliseconds(250))
        _ = filler.accept(chunk(endMs: 100))
        // Arrives 200 ms late: its audio started 200 ms after the previous chunk ended.
        let output = filler.accept(chunk(endMs: 400))
        #expect(output.count == 1)
        #expect(filler.streamEnd == at(200))
    }

    @Test func gapBeforeAChunkIsFilledWithSilence() {
        var filler = GapFiller(speaker: .them, origin: origin)
        _ = filler.accept(chunk(endMs: 100))
        let output = filler.accept(chunk(endMs: 2100))

        let silence = output.dropLast()
        #expect(sampleCount(Array(silence)) == 16_000 * 19 / 10)
        #expect(silence.allSatisfy { LevelMeter.isDigitalSilence($0.samples) })
        #expect(silence.allSatisfy { $0.samples.count <= GapFiller.fillChunkSamples && $0.speaker == .them })
        #expect(output.last?.samples.first == 100)
        #expect(filler.streamEnd == at(2100))
    }

    @Test func silencePiecesAreStampedWithTheirOwnEndTimes() {
        var filler = GapFiller(speaker: .me, origin: origin)
        let output = filler.fill(until: at(350))
        #expect(output.map(\.capturedAt) == [at(100), at(200), at(300), at(350)])
        #expect(output.map(\.samples.count) == [1600, 1600, 1600, 800])
    }

    @Test func timerFillsWhileTheSourceIsQuiet() {
        var filler = GapFiller(speaker: .them, origin: origin)
        _ = filler.accept(chunk(endMs: 100))
        #expect(filler.fill(until: at(300)).isEmpty)

        let first = filler.fill(until: at(400))
        #expect(sampleCount(first) == 16_000 * 3 / 10)
        let second = filler.fill(until: at(500))
        #expect(sampleCount(second) == 1600)
        #expect(filler.streamEnd == at(500))
    }

    @Test func audioAfterATimerFillOnlyGetsTheRemainingGap() {
        var filler = GapFiller(speaker: .them, origin: origin)
        _ = filler.accept(chunk(endMs: 100))
        _ = filler.fill(until: at(1000))

        let output = filler.accept(chunk(endMs: 1250))
        #expect(sampleCount(Array(output.dropLast())) == 16_000 * 15 / 100)
        #expect(filler.streamEnd == at(1250))
    }

    @Test func lateAudioOverlappingAFillIsKeptInFull() {
        var filler = GapFiller(speaker: .them, origin: origin)
        _ = filler.accept(chunk(endMs: 100))
        _ = filler.fill(until: at(1000))

        // Started at 900 ms, before the stream end the fill already reached.
        let output = filler.accept(chunk(endMs: 1000))
        #expect(output.count == 1)
        #expect(filler.streamEnd == at(1100))
    }

    @Test func realignFillsEvenAShortBreak() {
        var filler = GapFiller(speaker: .them, origin: origin, threshold: .milliseconds(250))
        _ = filler.accept(chunk(endMs: 100))
        filler.realign()
        // A rebuild that took 150 ms: below the threshold, but filled because it was announced.
        let output = filler.accept(chunk(endMs: 350))
        #expect(sampleCount(Array(output.dropLast())) == 16_000 * 15 / 100)
        #expect(filler.streamEnd == at(350))
    }

    @Test func realignOnlyAffectsTheNextChunk() {
        var filler = GapFiller(speaker: .them, origin: origin, threshold: .milliseconds(250))
        _ = filler.accept(chunk(endMs: 100))
        filler.realign()
        _ = filler.accept(chunk(endMs: 300))
        #expect(filler.accept(chunk(endMs: 500)).count == 1)
    }

    @Test func realignNeverDropsAudioThatIsAhead() {
        var filler = GapFiller(speaker: .them, origin: origin)
        _ = filler.accept(chunk(endMs: 100))
        _ = filler.accept(chunk(endMs: 150))
        filler.realign()
        #expect(filler.accept(chunk(endMs: 250)).count == 1)
        #expect(filler.streamEnd == at(300))
    }

    @Test func silenceBeforeTheFirstChunkCountsFromTheOrigin() {
        var filler = GapFiller(speaker: .them, origin: origin)
        let output = filler.accept(chunk(endMs: 1100))
        #expect(sampleCount(Array(output.dropLast())) == 16_000)
    }

    @Test func firstChunkCapturedBeforeTheOriginIsNotPadded() {
        var filler = GapFiller(speaker: .them, origin: origin)
        let output = filler.accept(chunk(endMs: 50))
        #expect(output.count == 1)
    }

    @Test func sampleClockConvertsExactly() {
        #expect(SampleClock.duration(ofSamples: 16_000) == .seconds(1))
        #expect(SampleClock.duration(ofSamples: 1) == .nanoseconds(62_500))
        #expect(SampleClock.samples(in: .seconds(1)) == 16_000)
        #expect(SampleClock.samples(in: .milliseconds(1500)) == 24_000)
        #expect(SampleClock.samples(in: .nanoseconds(62_499)) == 0)
        #expect(SampleClock.samples(in: .milliseconds(-5)) == 0)
        #expect(SampleClock.samples(in: SampleClock.duration(ofSamples: 57_600_123)) == 57_600_123)
    }
}
