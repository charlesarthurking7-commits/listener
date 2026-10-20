import Testing

@testable import ListenerCore

struct SilenceGateTests {
    private func frame(_ index: Int) -> ChannelFrame {
        ChannelFrame(
            chunk: AudioChunk(speaker: .me, samples: [Int16](repeating: Int16(index), count: 1_600), capturedAt: .now),
            start: Double(index) / 10)
    }

    private func starts(_ frames: [ChannelFrame]) -> [Int] {
        frames.map { Int(($0.start * 10).rounded()) }
    }

    @Test func holdsSilenceAndReleasesPreRollWhenSpeechStarts() {
        var gate = SilenceGate(preRoll: 0.3, tail: 1.0)
        for index in 0..<10 {
            #expect(gate.admit(frame(index), activity: []).isEmpty)
        }
        // Speech confirmed in frame 10, having begun at 0.95 s: frames from 0.65 s on
        // (6 to 9, since frame 6 ends at 0.7) come out ahead of frame 10.
        let released = gate.admit(frame(10), activity: [.speechStarted(at: 0.95)])
        #expect(starts(released) == [6, 7, 8, 9, 10])
        #expect(starts(gate.admit(frame(11), activity: [])) == [11])
    }

    @Test func keepsSendingForTheTailAfterSpeechEnds() {
        var gate = SilenceGate(preRoll: 0.3, tail: 1.0)
        _ = gate.admit(frame(0), activity: [.speechStarted(at: 0)])
        #expect(starts(gate.admit(frame(1), activity: [])) == [1])
        // Speech ended at 1.5 s, confirmed in frame 17: send until 2.5 s.
        var sent: [Int] = []
        for index in 2..<30 {
            let activity: [VoiceActivity] = index == 17 ? [.speechEnded(at: 1.5)] : []
            sent += starts(gate.admit(frame(index), activity: activity))
        }
        #expect(sent == Array(2..<25))
    }

    @Test func speechStartingAndEndingInOneFrameStillOpensTheGate() {
        var gate = SilenceGate(preRoll: 0.3, tail: 0.5)
        _ = gate.admit(frame(0), activity: [])
        let released = gate.admit(frame(1), activity: [.speechStarted(at: 0.1), .speechEnded(at: 0.18)])
        #expect(starts(released) == [0, 1])
        #expect(starts(gate.admit(frame(6), activity: [])) == [6])
        #expect(gate.admit(frame(7), activity: []).isEmpty)
    }

    @Test func heldAudioIsBounded() {
        var gate = SilenceGate(preRoll: 10.05, tail: 0)
        for index in 0..<200 {
            _ = gate.admit(frame(index), activity: [])
        }
        // Only the last 12.55 s (pre-roll plus 2.5 s) is kept, so a pre-roll reaching
        // back to the start gets frames from 7.4 s on.
        let released = gate.admit(frame(200), activity: [.speechStarted(at: 10)])
        #expect(starts(released).first == 74)
        #expect(starts(released).last == 200)
        #expect(released.count == 127)
    }
}
