import Testing

@testable import ListenerCore

struct SpeechSegmenterTests {
    private let segmenter = SpeechSegmenter(padding: 0)

    @Test func shortPausesStayInsideOneSegment() {
        let samples = Synth.track(seconds: 6, bursts: [1.0...2.0, 2.4...3.0])
        let result = segmenter.split(samples)
        #expect(result.bursts.count == 2)
        #expect(result.segments == [AudioSpan(start: 1.0, end: 3.0)])
    }

    @Test func longPausesStartANewSegment() {
        let samples = Synth.track(seconds: 6, bursts: [1.0...2.0, 3.0...4.0])
        #expect(
            segmenter.split(samples).segments == [AudioSpan(start: 1.0, end: 2.0), AudioSpan(start: 3.0, end: 4.0)])
    }

    @Test func speechThatNeverPausesIsCutBeforeTheLimit() {
        let samples = Synth.track(seconds: 75, bursts: [0...75])
        let result = segmenter.split(samples)
        #expect(result.longestBurst > 74)
        #expect(result.segments.count == 3)
        #expect(result.segments.allSatisfy { $0.duration <= 30 })
        for (earlier, later) in zip(result.segments, result.segments.dropFirst()) {
            #expect(earlier.end == later.start)
        }
    }

    @Test func cutsAtTheQuietestMomentNearTheLimit() throws {
        // Continuous sound with one softer stretch at 27 s, still loud enough to count as speech.
        var samples = Synth.track(seconds: 40, bursts: [0...40])
        let soft = Synth.tone(frequency: 440, seconds: 0.1, amplitude: 0.02)
        samples.replaceSubrange(27 * 16_000..<27 * 16_000 + soft.count, with: soft)
        let result = segmenter.split(samples)
        #expect(result.bursts.count == 1)
        let first = try #require(result.segments.first)
        #expect(abs(first.end - 27) <= 0.1)
    }

    @Test func paddingNeverMakesSegmentsOverlap() throws {
        let padded = SpeechSegmenter(padding: 0.5)
        let samples = Synth.track(seconds: 6, bursts: [1.0...2.0, 2.8...4.0])
        let segments = padded.split(samples).segments
        try #require(segments.count == 2)
        #expect(abs(segments[0].start - 0.5) < 1e-9)
        #expect(abs(segments[0].end - 2.4) < 1e-9)
        #expect(segments[0].end == segments[1].start)
        #expect(abs(segments[1].end - 4.5) < 1e-9)
    }

    @Test func reportsTheNoiseFloor() {
        let quiet = Synth.track(seconds: 4, bursts: [0...4], amplitude: 0.001)
        let result = segmenter.split(quiet)
        #expect(result.segments.isEmpty)
        #expect(result.quietDBFS < -60)
        #expect(result.quietDBFS > -70)
    }
}
