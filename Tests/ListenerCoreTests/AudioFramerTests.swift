import Testing

@testable import ListenerCore

struct AudioFramerTests {
    @Test func cutsArbitraryChunksIntoExactFrames() {
        let samples = (0..<10_000).map { Int16(truncatingIfNeeded: $0) }
        var framer = AudioFramer()
        var frames: [AudioChunk] = []
        for part in Synth.split(samples, sizes: [100, 1_500, 3_200, 10, 2_000]) {
            frames += framer.push(AudioChunk(speaker: .me, samples: Array(part), capturedAt: .now))
        }
        #expect(frames.count == 6)
        #expect(frames.allSatisfy { $0.samples.count == 1_600 && $0.speaker == .me })
        #expect(frames.flatMap(\.samples) == Array(samples[..<9_600]))
        #expect(framer.pendingCount == 400)

        let rest = framer.flush()
        #expect(rest?.samples == Array(samples[9_600...]))
        #expect(framer.flush() == nil)
    }

    @Test func frameTimeIsTheCaptureTimeOfItsLastSample() {
        let origin = ContinuousClock.now
        var framer = AudioFramer()
        // 4,000 samples captured with the last one at origin + 1 s: the first frame ends
        // 2,400 samples (150 ms) earlier, the second 800 samples (50 ms) earlier.
        let chunk = AudioChunk(
            speaker: .them, samples: [Int16](repeating: 1, count: 4_000), capturedAt: origin + .seconds(1))
        let frames = framer.push(chunk)
        #expect(frames.count == 2)
        #expect(frames[0].capturedAt == origin + .milliseconds(850))
        #expect(frames[1].capturedAt == origin + .milliseconds(950))

        // The next frame takes 800 leftover samples and 800 new ones, so it ends where
        // the new chunk's 800th sample was captured.
        let next = AudioChunk(
            speaker: .them, samples: [Int16](repeating: 2, count: 1_000), capturedAt: origin + .seconds(2))
        let more = framer.push(next)
        #expect(more.count == 1)
        #expect(more[0].capturedAt == origin + .milliseconds(1_987.5))
    }

    @Test func alignedChunksPassStraightThrough() {
        var framer = AudioFramer()
        let chunk = AudioChunk(speaker: .me, samples: [Int16](repeating: 3, count: 1_600), capturedAt: .now)
        let frames = framer.push(chunk)
        #expect(frames.count == 1)
        #expect(frames[0].capturedAt == chunk.capturedAt)
        #expect(frames[0].samples == chunk.samples)
    }

    @Test func customFrameLength() {
        var framer = AudioFramer(frameLength: 320)
        let frames = framer.push(
            AudioChunk(speaker: .me, samples: [Int16](repeating: 0, count: 1_000), capturedAt: .now))
        #expect(frames.map(\.samples.count) == [320, 320, 320])
        #expect(framer.pendingCount == 40)
    }
}
