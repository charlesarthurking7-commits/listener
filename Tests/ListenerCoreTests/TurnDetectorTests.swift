import Testing

@testable import ListenerCore

/// Drives a TurnDetector the way CallSession does: 100 ms frames per channel, voice
/// activity and speech-to-text events, collecting every turn that closes.
private struct Harness {
    var detector = TurnDetector(settings: TurnSettings())
    /// Session time minus channel time for each channel's audio.
    var offsets: [Speaker: Double] = [.me: 0, .them: 0]
    var closed: [Turn] = []
    var changes = 0
    private var tenths: [Speaker: Int] = [:]

    var turns: [Turn] { detector.snapshot.turns }

    mutating func play(_ speaker: Speaker, to seconds: Double) {
        let target = Int((seconds * 10).rounded())
        var tenth = tenths[speaker, default: 0]
        while tenth < target {
            let frame = Double(tenth) / 10..<Double(tenth + 1) / 10
            apply(detector.audioProgress(speaker, frame: frame, capturedAt: frame.upperBound + offsets[speaker]!))
            tenth += 1
        }
        tenths[speaker] = tenth
    }

    mutating func play(to seconds: Double) {
        play(.me, to: seconds)
        play(.them, to: seconds)
    }

    mutating func speech(_ speaker: Speaker, _ range: ClosedRange<Double>) {
        started(speaker, at: range.lowerBound)
        ended(speaker, at: range.upperBound)
    }

    mutating func started(_ speaker: Speaker, at time: Double) {
        apply(detector.voiceActivity(.speechStarted(at: time), speaker: speaker))
    }

    mutating func ended(_ speaker: Speaker, at time: Double) {
        apply(detector.voiceActivity(.speechEnded(at: time), speaker: speaker))
    }

    mutating func final(_ speaker: Speaker, _ text: String, _ range: ClosedRange<Double>?) {
        let event = SpeechEvent(
            kind: .final, text: text, audioStart: range?.lowerBound, audioEnd: range?.upperBound)
        apply(detector.speechEvent(event, speaker: speaker))
    }

    mutating func interim(_ speaker: Speaker, _ text: String) {
        apply(detector.speechEvent(SpeechEvent(kind: .interim, text: text), speaker: speaker))
    }

    mutating func finish() {
        apply(detector.finish())
    }

    mutating func apply(_ update: TurnDetector.Update) {
        closed += update.closed
        changes += update.changed ? 1 : 0
    }
}

private func near(_ value: Double?, _ expected: Double) -> Bool {
    abs((value ?? .nan) - expected) < 1e-9
}

struct TurnDetectorTests {
    @Test func aFinalBecomesATurnInSessionTime() throws {
        var harness = Harness()
        harness.offsets[.them] = 5
        harness.play(to: 2)
        harness.speech(.them, 1.0...1.8)
        harness.interim(.them, "hello")
        harness.final(.them, " hello there ", 1.0...1.8)
        let turn = try #require(harness.turns.first)
        #expect(harness.turns.count == 1)
        #expect(turn.id == 1 && turn.speaker == .them && turn.text == "hello there")
        #expect(near(turn.start, 6.0) && near(turn.end, 6.8))
        #expect(harness.detector.snapshot.interim.isEmpty)
        #expect(near(harness.detector.sessionTime(.them, channelTime: 1.5), 6.5))
    }

    @Test func interimTextIsShownAndOnlyChangesWhenItDiffers() {
        var harness = Harness()
        harness.interim(.me, "so the")
        harness.interim(.me, "so the")
        harness.interim(.them, "right")
        #expect(harness.changes == 2)
        #expect(harness.detector.snapshot.interim == [.me: "so the", .them: "right"])
        harness.interim(.me, "")
        #expect(harness.detector.snapshot.interim == [.them: "right"])
        #expect(harness.detector.revision == 0)
    }

    @Test func consecutiveFinalsWithAShortGapMerge() {
        var harness = Harness()
        harness.play(to: 0.4)
        harness.started(.them, at: 0.2)
        harness.play(to: 1.2)
        harness.ended(.them, at: 1.0)
        harness.play(to: 1.3)
        harness.final(.them, "Can you check", 0.2...1.0)
        harness.started(.them, at: 1.3)
        harness.play(to: 2.2)
        harness.ended(.them, at: 2.0)
        harness.play(to: 2.3)
        harness.final(.them, "the EUR fills?", 1.3...2.0)
        #expect(harness.turns.map(\.text) == ["Can you check the EUR fills?"])
        #expect(near(harness.turns.first?.start, 0.2) && near(harness.turns.first?.end, 2.0))
        #expect(harness.detector.revision == 2)
        #expect(harness.closed.isEmpty)
    }

    @Test func aLongPauseStartsANewTurnAndClosesTheOldOne() {
        var harness = Harness()
        harness.speech(.them, 0.0...1.0)
        harness.final(.them, "First.", 0.0...1.0)
        harness.speech(.them, 1.6...2.5)
        harness.play(to: 2.6)
        harness.final(.them, "Second.", 1.8...2.5)
        #expect(harness.turns.map(\.text) == ["First.", "Second."])
        #expect(harness.turns.map(\.id) == [1, 2])
        #expect(harness.closed.map(\.id) == [1])
    }

    @Test func someoneElseSpeakingInTheGapKeepsTurnsApart() {
        var harness = Harness()
        harness.play(to: 1.5)
        harness.final(.them, "So the price", 0.0...1.0)
        harness.final(.me, "Yeah.", 1.1...1.3)
        harness.final(.them, "was off.", 1.4...2.0)
        #expect(harness.turns.map(\.speaker) == [.them, .me, .them])
        #expect(harness.turns.map(\.text) == ["So the price", "Yeah.", "was off."])
    }

    @Test func voiceActivityAloneIsEnoughToKeepTurnsApart() {
        var harness = Harness()
        harness.play(to: 1.5)
        harness.final(.them, "So the price", 0.0...1.0)
        // Me's final has not arrived yet, but its voice activity has.
        harness.speech(.me, 1.1...1.3)
        harness.final(.them, "was off.", 1.4...2.0)
        #expect(harness.turns.map(\.text) == ["So the price", "was off."])

        var talking = Harness()
        talking.play(to: 1.5)
        talking.final(.them, "So the price", 0.0...1.0)
        talking.started(.me, at: 1.2)
        talking.final(.them, "was off.", 1.4...2.0)
        #expect(talking.turns.count == 2)
    }

    @Test func lateFinalsAreOrderedByStartWithStableIDs() {
        var harness = Harness()
        harness.play(.them, to: 7)
        harness.play(.me, to: 4.6)
        harness.final(.them, "Later words", 5...6)
        harness.final(.me, "Earlier words", 3...4)
        #expect(harness.turns.map(\.text) == ["Earlier words", "Later words"])
        #expect(harness.turns.map(\.id) == [2, 1])
        harness.final(.me, "and more", 4.2...4.5)
        #expect(harness.turns.map(\.text) == ["Earlier words and more", "Later words"])
    }

    @Test func aTurnClosesAfterSilenceOnceItsFinalIsIn() {
        var harness = Harness()
        harness.speech(.them, 0.2...1.0)
        harness.play(.them, to: 1.2)
        harness.final(.them, "Done.", 0.2...1.0)
        harness.play(.them, to: 1.6)
        #expect(harness.closed.isEmpty)
        harness.play(.them, to: 1.7)
        #expect(harness.closed.map(\.text) == ["Done."])
    }

    @Test func aFinalArrivingAfterTheSilenceClosesAtOnce() {
        var harness = Harness()
        harness.speech(.them, 0.2...1.0)
        harness.play(.them, to: 3)
        harness.final(.them, "Late.", 0.2...1.0)
        #expect(harness.closed.map(\.text) == ["Late."])
    }

    @Test func aTurnStaysOpenWhileItsSpeakerTalksButNotForever() {
        var harness = Harness()
        harness.play(.them, to: 1)
        harness.final(.them, "Words.", 0...1)
        harness.started(.them, at: 1.2)
        harness.play(.them, to: 10)
        #expect(harness.closed.isEmpty)
        harness.play(.them, to: 16)
        #expect(harness.closed.map(\.text) == ["Words."])
    }

    @Test func finalsWithoutTimesUseVoiceActivity() {
        var harness = Harness()
        harness.offsets[.me] = 1
        harness.speech(.me, 2.0...3.0)
        harness.play(.me, to: 3.5)
        harness.final(.me, "No timestamps.", nil)
        #expect(harness.turns.map(\.text) == ["No timestamps."])
        #expect(near(harness.turns.first?.start, 3.0) && near(harness.turns.first?.end, 4.0))
    }

    @Test func captureGapsShiftLaterAudio() {
        var detector = TurnDetector(settings: TurnSettings())
        _ = detector.audioProgress(.me, frame: 0..<0.1, capturedAt: 0.1)
        // Half a second of audio went missing before the next frame.
        _ = detector.audioProgress(.me, frame: 0.1..<0.2, capturedAt: 0.7)
        _ = detector.speechEvent(SpeechEvent(kind: .final, text: "x", audioStart: 0.15, audioEnd: 0.2), speaker: .me)
        #expect(near(detector.snapshot.turns.first?.start, 0.65))
        #expect(near(detector.snapshot.turns.first?.end, 0.7))
    }

    @Test func emptyFinalsOnlyClearInterimText() {
        var harness = Harness()
        harness.interim(.me, "um")
        harness.final(.me, "  ", 0...0.5)
        #expect(harness.turns.isEmpty)
        #expect(harness.detector.snapshot.interim.isEmpty)
        #expect(harness.detector.revision == 0)
    }

    @Test func finishKeepsUnfinishedSpeechAndClosesEverything() {
        var harness = Harness()
        harness.play(to: 3)
        harness.speech(.them, 0.5...1.5)
        harness.final(.them, "Question?", 0.5...1.5)
        harness.started(.me, at: 2.0)
        harness.interim(.me, "I think")
        harness.finish()
        #expect(harness.turns.map(\.text) == ["Question?", "I think"])
        #expect(near(harness.turns[1].start, 2.0) && near(harness.turns[1].end, 3.0))
        #expect(harness.closed.map(\.text) == ["Question?", "I think"])
        #expect(harness.detector.snapshot.interim.isEmpty)
    }
}
