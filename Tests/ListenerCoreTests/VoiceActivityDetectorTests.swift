import Testing

@testable import ListenerCore

struct VoiceActivityDetectorTests {
    private func detect(_ samples: [Int16], detector: VoiceActivityDetector = VoiceActivityDetector())
        -> [VoiceActivity]
    {
        var detector = detector
        var events = detector.process(samples)
        if let end = detector.finish() {
            events.append(end)
        }
        return events
    }

    @Test func silenceProducesNothing() {
        #expect(detect(Synth.silence(seconds: 3)).isEmpty)
    }

    @Test func burstIsReportedFromFirstToLastLoudFrame() {
        let samples = Synth.track(seconds: 3, bursts: [0.5...1.5])
        #expect(detect(samples) == [.speechStarted(at: 0.5), .speechEnded(at: 1.5)])
    }

    @Test func unalignedBurstIsWithinOneFrame() throws {
        let samples = Synth.track(seconds: 3, bursts: [0.513...1.487])
        let events = detect(samples)
        try #require(events.count == 2)
        guard case .speechStarted(let start) = events[0], case .speechEnded(let end) = events[1] else {
            Issue.record("unexpected events \(events)")
            return
        }
        #expect(abs(start - 0.513) <= 0.02)
        #expect(abs(end - 1.487) <= 0.02)
    }

    @Test func burstsShorterThanMinimumSpeechAreIgnored() {
        let clicks = Synth.track(seconds: 3, bursts: [0.5...0.6, 1.5...1.64])
        #expect(detect(clicks).isEmpty)
        let justLongEnough = Synth.track(seconds: 3, bursts: [0.5...0.66])
        #expect(detect(justLongEnough) == [.speechStarted(at: 0.5), .speechEnded(at: 0.66)])
    }

    /// Each key is loud for a frame or two, and steady typing puts a key well inside the
    /// hangover of the one before, whatever the level.
    @Test(arguments: [5.0, 6, 8, 10, 12], [-40.0, -35, -30, -20])
    func typingIsNotSpeech(keysPerSecond: Double, levelDBFS: Double) {
        let typing = Synth.keystrokes(seconds: 10, perSecond: keysPerSecond, levelDBFS: levelDBFS)
        #expect(detect(typing).isEmpty)
    }

    /// Typing that goes on after the speaker stops does not keep their speech going. A key
    /// within the 200 ms that confirms speech can still count as part of it.
    @Test(arguments: [(6.0, -40.0), (8, -35), (10, -30)])
    func typingThroughSpeechEndsWhereTheSpeechDoes(keysPerSecond: Double, levelDBFS: Double) throws {
        let speech = Synth.track(seconds: 6, bursts: [0.5...1.5], amplitude: 0.05)
        let typing = Synth.keystrokes(seconds: 6, perSecond: keysPerSecond, levelDBFS: levelDBFS)
        let events = detect(Synth.mix(speech, typing))
        try #require(events.count == 2)
        guard case .speechStarted(let start) = events[0], case .speechEnded(let end) = events[1] else {
            Issue.record("unexpected events \(events)")
            return
        }
        #expect(start > 0.3 && start <= 0.5)
        #expect(end >= 1.5 && end < 1.7)
    }

    @Test func shortDipsBetweenWordsDoNotSplitSpeech() {
        let samples = Synth.track(seconds: 3, bursts: [0.5...1.0, 1.1...1.5])
        #expect(detect(samples) == [.speechStarted(at: 0.5), .speechEnded(at: 1.5)])
    }

    @Test func pauseLongerThanHangoverSplitsSpeech() {
        let samples = Synth.track(seconds: 3, bursts: [0.5...1.0, 1.3...1.8])
        #expect(
            detect(samples) == [
                .speechStarted(at: 0.5), .speechEnded(at: 1.0), .speechStarted(at: 1.3), .speechEnded(at: 1.8),
            ])
    }

    @Test func soundBelowThresholdIsNotSpeech() {
        // -3 dBFS for a sine, so 0.003 of full scale sits near -53 dBFS.
        let quiet = Synth.track(seconds: 2, bursts: [0.5...1.5], amplitude: 0.003)
        #expect(detect(quiet).isEmpty)
        let louder = VoiceActivityDetector(thresholdDBFS: -60)
        #expect(detect(quiet, detector: louder) == [.speechStarted(at: 0.5), .speechEnded(at: 1.5)])
    }

    @Test func resultsDoNotDependOnHowAudioIsSplit() {
        let samples = Synth.track(seconds: 4, bursts: [0.31...0.97, 1.42...2.11, 2.5...2.58, 3.0...3.9])
        let whole = detect(samples)
        for sizes in [[1], [7, 319, 1600], [1600], [4_096, 3]] {
            var detector = VoiceActivityDetector()
            var events: [VoiceActivity] = []
            for part in Synth.split(samples, sizes: sizes) {
                events += detector.process(part)
            }
            if let end = detector.finish() {
                events.append(end)
            }
            #expect(events == whole, "sizes \(sizes)")
        }
    }

    @Test func startIsConfirmedAfterMinimumSpeechAndEndAfterHangover() {
        var detector = VoiceActivityDetector(minSpeechMs: 150, hangoverMs: 200)
        let samples = Synth.track(seconds: 3, bursts: [1.0...2.0])
        var reportedAt: [Double] = []
        for frame in Synth.split(samples, sizes: [320]) {
            if !detector.process(frame).isEmpty {
                reportedAt.append(detector.position)
            }
        }
        #expect(reportedAt.count == 2)
        #expect(abs(reportedAt[0] - 1.16) < 1e-9)
        #expect(abs(reportedAt[1] - 2.2) < 1e-9)
    }

    @Test func finishClosesSpeechThatIsStillGoing() {
        var detector = VoiceActivityDetector()
        #expect(detector.process(Synth.track(seconds: 1, bursts: [0.5...1.0])) == [.speechStarted(at: 0.5)])
        #expect(detector.isSpeaking)
        #expect(detector.finish() == .speechEnded(at: 1.0))
        #expect(!detector.isSpeaking)
        #expect(detector.finish() == nil)
    }

    @Test func settingsDriveThresholdAndMinimumSpeech() {
        var settings = TurnSettings()
        settings.minSpeechMs = 400
        let detector = VoiceActivityDetector(settings: settings)
        #expect(detect(Synth.track(seconds: 2, bursts: [0.5...0.8]), detector: detector).isEmpty)
        #expect(detect(Synth.track(seconds: 2, bursts: [0.5...0.92]), detector: detector).count == 2)
    }
}
