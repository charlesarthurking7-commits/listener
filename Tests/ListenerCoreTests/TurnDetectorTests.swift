import Testing

@testable import ListenerCore

/// Drives a TurnDetector the way CallSession does: 100 ms frames per channel, voice
/// activity and speech-to-text events, collecting every turn that closes.
private struct Harness {
    var detector = TurnDetector(settings: TurnSettings())
    /// Session time minus channel time for each channel's audio.
    var offsets: [Speaker: Double] = [.me: 0, .them: 0]
    /// Replay speed: how many seconds of audio go by per second of session time.
    var speed = 1.0
    var closed: [Turn] = []
    var changes = 0
    private var tenths: [Speaker: Int] = [:]

    var turns: [Turn] { detector.snapshot.turns }

    mutating func play(_ speaker: Speaker, to seconds: Double) {
        let target = Int((seconds * 10).rounded())
        var tenth = tenths[speaker, default: 0]
        while tenth < target {
            let frame = Double(tenth) / 10..<Double(tenth + 1) / 10
            apply(detector.audioProgress(speaker, frame: frame, capturedAt: capturedAt(frame, speaker)))
            tenth += 1
        }
        tenths[speaker] = tenth
    }

    /// The next 100 ms frame, with the voice activity found in it.
    mutating func frame(_ speaker: Speaker, activity: [VoiceActivity]) {
        let tenth = tenths[speaker, default: 0]
        let frame = Double(tenth) / 10..<Double(tenth + 1) / 10
        apply(
            detector.audioProgress(speaker, frame: frame, capturedAt: capturedAt(frame, speaker), activity: activity))
        tenths[speaker] = tenth + 1
    }

    private func capturedAt(_ frame: Range<Double>, _ speaker: Speaker) -> Double {
        frame.upperBound / speed + offsets[speaker]!
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

    mutating func interim(_ speaker: Speaker, _ text: String, _ range: ClosedRange<Double>? = nil) {
        let event = SpeechEvent(
            kind: .interim, text: text, audioStart: range?.lowerBound, audioEnd: range?.upperBound)
        apply(detector.speechEvent(event, speaker: speaker))
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
        harness.speech(.them, 1.8...2.5)
        harness.play(to: 2.6)
        harness.final(.them, "Second.", 1.8...2.5)
        #expect(harness.turns.map(\.text) == ["First.", "Second."])
        #expect(harness.turns.map(\.id) == [1, 2])
        #expect(harness.closed.map(\.id) == [1])
    }

    @Test func someoneElseSpeakingInTheGapKeepsTurnsApart() {
        var harness = Harness()
        harness.speech(.them, 0.0...1.0)
        harness.speech(.me, 1.1...1.3)
        harness.play(to: 1.5)
        harness.final(.them, "So the price", 0.0...1.0)
        harness.final(.me, "Yeah.", 1.1...1.3)
        harness.final(.them, "was off.", 1.4...2.0)
        #expect(harness.turns.map(\.speaker) == [.them, .me, .them])
        #expect(harness.turns.map(\.text) == ["So the price", "Yeah.", "was off."])
    }

    @Test func voiceActivityAloneIsEnoughToKeepTurnsApart() {
        var harness = Harness()
        harness.speech(.them, 0.0...1.0)
        harness.play(to: 1.5)
        harness.final(.them, "So the price", 0.0...1.0)
        // Me's final has not arrived yet, but its voice activity has.
        harness.speech(.me, 1.1...1.3)
        harness.final(.them, "was off.", 1.4...2.0)
        #expect(harness.turns.map(\.text) == ["So the price", "was off."])

        var talking = Harness()
        talking.speech(.them, 0.0...1.0)
        talking.play(to: 1.5)
        talking.final(.them, "So the price", 0.0...1.0)
        talking.started(.me, at: 1.2)
        talking.final(.them, "was off.", 1.4...2.0)
        #expect(talking.turns.count == 2)
    }

    @Test func aFillerMadeUpInSilenceIsDropped() {
        var harness = Harness()
        harness.speech(.me, 0.5...1.5)
        harness.play(to: 5)
        harness.final(.me, "Hi, go ahead.", 0.4...1.6)
        harness.interim(.me, "Yeah", 1.6...3.8)
        #expect(harness.detector.snapshot.interim.isEmpty)
        harness.final(.me, "Yeah.", 1.6...4.4)
        #expect(harness.turns.map(\.text) == ["Hi, go ahead."])
        #expect(harness.detector.revision == 1)
    }

    @Test func textWithoutWordsIsIgnored() {
        var harness = Harness()
        harness.interim(.me, ".")
        harness.final(.me, "…", nil)
        #expect(harness.detector.snapshot.interim.isEmpty)
        #expect(harness.turns.isEmpty)
        #expect(harness.changes == 0)
    }

    @Test func longerTextWithNoSpeechUnderItIsKept() {
        // More likely someone too quiet for the voice activity detector than made up.
        var harness = Harness()
        harness.play(to: 4)
        harness.final(.them, "I'll send the report this afternoon.", 1.0...3.0)
        #expect(harness.turns.map(\.text) == ["I'll send the report this afternoon."])
    }

    @Test func aFinalOlderThanTheSpeechKeptIsNeverTakenForMadeUp() {
        var harness = Harness()
        for second in 0..<70 {
            harness.speech(.them, Double(second) + 10...Double(second) + 10.5)
        }
        harness.play(to: 90)
        harness.final(.them, "Yes.", 1...2)
        #expect(harness.turns.map(\.text) == ["Yes."])
    }

    /// A channel behind the other has only said it was speaking up to the audio it has
    /// delivered; whether it went on speaking is not known yet.
    @Test func speechStillGoingOnALaggingChannelOnlyCountsUpToItsAudio() {
        var harness = Harness()
        harness.play(.them, to: 0.5)
        harness.started(.them, at: 0.2)
        harness.speech(.me, 1.0...2.0)
        harness.play(.me, to: 2.3)
        harness.final(.me, "First part,", 1.0...2.0)
        harness.speech(.me, 2.4...3.4)
        harness.play(.me, to: 3.6)
        harness.final(.me, "second part.", 2.4...3.4)
        #expect(harness.turns.map(\.text) == ["First part, second part."])
    }

    @Test func lateFinalsAreOrderedByStartWithStableIDs() {
        var harness = Harness()
        harness.speech(.them, 5...6)
        harness.speech(.me, 3...4)
        harness.speech(.me, 4.2...4.5)
        harness.play(.them, to: 7)
        harness.play(.me, to: 4.6)
        harness.final(.them, "Later words", 5...6)
        harness.final(.me, "Earlier words", 3...4)
        #expect(harness.turns.map(\.text) == ["Earlier words", "Later words"])
        #expect(harness.turns.map(\.id) == [2, 1])
        harness.final(.me, "and more", 4.2...4.5)
        #expect(harness.turns.map(\.text) == ["Earlier words and more", "Later words"])
    }

    /// 700 ms of silence, plus the 160 ms the detector needs to report a start that
    /// might have come at the end of it.
    @Test func aTurnClosesAfterSilenceOnceItsFinalIsIn() {
        var harness = Harness()
        harness.speech(.them, 0.2...1.0)
        harness.play(.them, to: 1.2)
        harness.final(.them, "Done.", 0.2...1.0)
        harness.play(.them, to: 1.8)
        #expect(harness.closed.isEmpty)
        harness.play(.them, to: 1.9)
        #expect(harness.closed.map(\.text) == ["Done."])
    }

    @Test func aStartReportedWithTheFrameThatEndsTheSilenceKeepsTheTurnOpen() {
        var harness = Harness()
        harness.speech(.them, 1.0...2.0)
        harness.play(.them, to: 2.3)
        harness.final(.them, "Which accounts", 1.0...2.0)
        harness.play(.them, to: 2.8)
        // Speech came back 0.65 s after it stopped; the detector reports it 160 ms in.
        harness.frame(.them, activity: [.speechStarted(at: 2.65)])
        #expect(harness.closed.isEmpty)
        harness.play(.them, to: 3.6)
        harness.frame(.them, activity: [.speechEnded(at: 3.5)])
        harness.final(.them, "were affected?", nil)
        #expect(harness.turns.map(\.text) == ["Which accounts were affected?"])
    }

    /// Recognisers often finalise later than the silence that closes a turn. Speech the
    /// speaker went on with after a short pause is still waiting for its final then,
    /// and may belong to the turn, so the turn waits for it.
    @Test func aTurnWaitsForTheFinalOfSpeechThatFollowedAShortPause() {
        var harness = Harness()
        harness.speech(.them, 1.0...2.0)
        harness.play(.them, to: 2.3)
        harness.final(.them, "Which accounts were affected,", 1.0...2.0)
        harness.speech(.them, 2.4...3.4)
        harness.play(.them, to: 4.5)
        #expect(harness.closed.isEmpty)
        harness.final(.them, "and by how much?", 2.4...3.4)
        #expect(harness.turns.map(\.text) == ["Which accounts were affected, and by how much?"])
        #expect(harness.closed.map(\.text) == ["Which accounts were affected, and by how much?"])
    }

    /// Recognisers also split speech that has no pause in it, and the second final can
    /// come later than the silence after it.
    @Test func aTurnWaitsForTheFinalOfSpeechThatRanOnPastItsFinal() {
        var harness = Harness()
        harness.started(.them, at: 1.0)
        harness.play(.them, to: 2.3)
        harness.final(.them, "Which accounts were affected,", 1.0...2.0)
        harness.play(.them, to: 3.5)
        harness.ended(.them, at: 3.4)
        harness.play(.them, to: 4.6)
        #expect(harness.closed.isEmpty)
        harness.final(.them, "and by how much?", nil)
        #expect(harness.turns.map(\.text) == ["Which accounts were affected, and by how much?"])
    }

    /// A recogniser's delay is real time, which fast replay packs into more audio: a
    /// final half a second late at eight times speed comes 4 s of audio later.
    @Test func aSlowFinalStillJoinsItsTurnInFastReplay() {
        var harness = Harness()
        harness.speed = 8
        harness.speech(.them, 1.0...2.0)
        harness.play(.them, to: 2.3)
        harness.final(.them, "Which accounts were affected,", 1.0...2.0)
        harness.speech(.them, 2.4...3.4)
        harness.play(.them, to: 8.2)
        #expect(harness.closed.isEmpty)
        harness.final(.them, "and by how much?", 2.4...3.4)
        #expect(harness.turns.map(\.text) == ["Which accounts were affected, and by how much?"])
        harness.play(.them, to: 9)
        #expect(harness.closed.count == 1)
    }

    /// A pause is a stretch of audio, however fast it is replayed.
    @Test func aPauseLongerThanTheSilenceSplitsTurnsInFastReplayToo() {
        var harness = Harness()
        harness.speed = 4
        harness.speech(.them, 1.0...2.0)
        harness.play(.them, to: 2.3)
        harness.final(.them, "Fine.", 1.0...2.0)
        harness.play(.them, to: 2.7)
        harness.speech(.them, 2.75...3.5)
        harness.play(.them, to: 3.6)
        harness.final(.them, "What's the reference?", 2.75...3.5)
        #expect(harness.turns.map(\.text) == ["Fine.", "What's the reference?"])
    }

    /// Speech that never gets a final, a cough say, holds the turn open only so long.
    @Test func speechThatNeverGetsAFinalOnlyDelaysTheClose() {
        var harness = Harness()
        harness.speech(.them, 1.0...2.0)
        harness.play(.them, to: 2.3)
        harness.final(.them, "Right.", 1.0...2.0)
        harness.speech(.them, 2.4...2.7)
        harness.play(.them, to: 3.4)
        #expect(harness.closed.isEmpty)
        harness.play(.them, to: 6)
        #expect(harness.closed.map(\.text) == ["Right."])
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
        harness.speech(.them, 0...1)
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

    @Test func aStartAtThePreviousFinalsEndIsNotTrusted() {
        // Chirp 3 reports a final's start as the end of the previous final, which would
        // make the 1.5 s pause below look like none.
        var harness = Harness()
        harness.speech(.them, 0.5...1.5)
        harness.play(.them, to: 1.6)
        harness.final(.them, "First.", 0.5...1.5)
        harness.speech(.them, 3.0...4.0)
        harness.final(.them, "Second.", 1.5...4.0)
        #expect(harness.turns.map(\.text) == ["First.", "Second."])
        #expect(near(harness.turns.last?.start, 3.0))
    }

    @Test func soundsLongBeforeTheRecognisersStartAreNotTheSpeech() {
        // The mic picks up sounds while the other side talks for a minute. A reply after
        // that starts at its words, not at the first sound, so it follows what it answers.
        // Apple's start includes some of the silence before the first word.
        var harness = Harness()
        harness.speech(.me, 0.5...1.5)
        harness.play(to: 1.6)
        harness.final(.me, "Sounds good.", 0.5...1.5)
        for sound in stride(from: 6.0, to: 68, by: 3) {
            harness.speech(.me, sound...(sound + 0.4))
        }
        harness.speech(.them, 8.0...34.0)
        harness.play(to: 35)
        harness.final(.them, "So the next ticket is the regulation change.", 8.0...34.0)
        harness.speech(.me, 72.0...73.2)
        harness.play(to: 74)
        harness.final(.me, "Yeah, that makes sense.", 70.6...73.1)
        #expect(
            harness.turns.map(\.text) == [
                "Sounds good.", "So the next ticket is the regulation change.", "Yeah, that makes sense.",
            ])
        #expect(near(harness.turns.last?.start, 72.0))
    }

    @Test func aReplyDuringTheOtherSidesSpeechComesBeforeWhatTheySaidAfterIt() {
        // "Yeah." lands while Them is still talking. Their next final must not join the
        // turn that started before it, or their question reads as already answered.
        var harness = Harness()
        harness.started(.them, at: 0)
        harness.speech(.me, 12.0...12.5)
        harness.play(.me, to: 12.6)
        harness.final(.me, "Yeah.", 12.0...12.5)
        harness.play(.them, to: 15.1)
        harness.ended(.them, at: 15.0)
        harness.final(.them, "We reran the overnight batch after the outage.", 0...15.0)
        harness.started(.them, at: 15.4)
        harness.play(to: 24.1)
        harness.ended(.them, at: 24.0)
        harness.final(.them, "Can you check it finished?", 15.4...24.0)
        #expect(
            harness.turns.map(\.text) == [
                "We reran the overnight batch after the outage.", "Yeah.", "Can you check it finished?",
            ])
        #expect(harness.turns.map(\.speaker) == [.them, .me, .them])
    }

    @Test func speechTheRecogniserSplitsWithoutAPauseStaysOneTurn() {
        var harness = Harness()
        harness.started(.them, at: 0.5)
        harness.play(.them, to: 2.2)
        harness.final(.them, "One long", nil)
        harness.play(.them, to: 4.0)
        harness.ended(.them, at: 4.0)
        harness.final(.them, "sentence.", nil)
        #expect(harness.turns.map(\.text) == ["One long sentence."])
        #expect(near(harness.turns.first?.start, 0.5) && near(harness.turns.first?.end, 4.0))
    }

    @Test func captureGapsShiftLaterAudio() {
        var detector = TurnDetector(settings: TurnSettings())
        _ = detector.audioProgress(.me, frame: 0..<0.1, capturedAt: 0.1)
        // Half a second of audio went missing before the next frame.
        _ = detector.audioProgress(.me, frame: 0.1..<0.2, capturedAt: 0.7)
        _ = detector.audioProgress(.me, frame: 0.2..<0.3, capturedAt: 0.8, activity: [.speechStarted(at: 0.25)])
        _ = detector.speechEvent(SpeechEvent(kind: .final, text: "x", audioStart: 0.25, audioEnd: 0.3), speaker: .me)
        #expect(near(detector.snapshot.turns.first?.start, 0.75))
        #expect(near(detector.snapshot.turns.first?.end, 0.8))
    }

    @Test func fastReplayMapsAudioOntoTheShorterSessionTime() {
        var detector = TurnDetector(settings: TurnSettings())
        // Four times real time: each 100 ms frame arrives 25 ms after the one before.
        for index in 0..<10 {
            let frame = Double(index) / 10..<Double(index + 1) / 10
            _ = detector.audioProgress(.them, frame: frame, capturedAt: 2 + frame.upperBound / 4)
        }
        _ = detector.voiceActivity(.speechStarted(at: 0.33), speaker: .them)
        _ = detector.voiceActivity(.speechEnded(at: 0.47), speaker: .them)
        _ = detector.speechEvent(SpeechEvent(kind: .final, text: "x", audioStart: 0.33, audioEnd: 0.47), speaker: .them)
        #expect(near(detector.snapshot.turns.first?.start, 2.0825))
        #expect(near(detector.snapshot.turns.first?.end, 2.1175))
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
