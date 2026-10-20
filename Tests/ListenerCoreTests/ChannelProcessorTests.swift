import Testing

@testable import ListenerCore

struct ChannelProcessorTests {
    private func run(_ samples: [Int16], skipSilence: Bool = false, chunkSize: Int = 441) -> [FrameReport] {
        var processor = ChannelProcessor(turns: TurnSettings(), skipSilence: skipSilence)
        var reports: [FrameReport] = []
        for chunk in samples.chunks(of: chunkSize) {
            reports += processor.process(chunk)
        }
        return reports + processor.finish()
    }

    @Test func framesEverythingAndSendsItAllWhenNotSkippingSilence() {
        let samples = Synth.track(seconds: 2.05, bursts: [0.5...1.2])
        let reports = run(samples)
        #expect(reports.count == 21)
        #expect(reports.dropLast().allSatisfy { $0.frame.chunk.samples.count == 1_600 })
        #expect(reports.last?.frame.chunk.samples.count == 800)
        #expect(reports.map(\.frame.start) == (0..<21).map { Double($0) / 10 })
        #expect(reports.allSatisfy { $0.toSpeech.count == 1 && $0.toSpeech[0].start == $0.frame.start })
        #expect(reports.flatMap(\.activity) == [.speechStarted(at: 0.5), .speechEnded(at: 1.2)])
        #expect(abs(reports.reduce(0) { $0 + $1.speechSeconds } - 2.05) < 1e-9)
    }

    @Test func skippingSilenceSendsOnlySpeechWithPreRollAndTail() {
        let samples = Synth.track(seconds: 6, bursts: [2.05...3.0])
        let sent = run(samples, skipSilence: true).flatMap(\.toSpeech)
        // Speech from 2.04 s (its first 20 ms frame), so the 0.3 s pre-roll reaches into
        // the frame starting at 1.7 s; then the speech, and a 1 s tail to 4.0 s.
        #expect(sent.first?.start == 1.7)
        #expect(abs((sent.last?.end ?? 0) - 4.0) < 1e-9)
        #expect(zip(sent, sent.dropFirst()).allSatisfy { abs($0.end - $1.start) < 1e-9 })
    }

    @Test func raisesTheSilenceAlarmOnceAfterThirtySecondsOfZeros() {
        let reports = run(Synth.silence(seconds: 40), chunkSize: 1_600)
        let alarms = reports.indices.filter { reports[$0].silenceAlarm }
        #expect(alarms == [299])
    }

    @Test func anySoundDisarmsTheSilenceAlarm() {
        var samples = Synth.silence(seconds: 40)
        samples[16_000] = 1
        #expect(!run(samples).contains { $0.silenceAlarm })
    }

    @Test func finishEndsSpeechThatRunsToTheEndOfTheAudio() {
        let samples = Synth.track(seconds: 1.0, bursts: [0.5...1.0])
        let reports = run(samples, chunkSize: 1_600)
        #expect(reports.flatMap(\.activity) == [.speechStarted(at: 0.5), .speechEnded(at: 1.0)])
        #expect(reports.last?.frame.chunk.samples.isEmpty == true)
        #expect(reports.last?.toSpeech.isEmpty == true)
    }
}
