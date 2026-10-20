import ListenerCore
import Testing

@testable import GoogleSpeech

struct ChannelTimelineTests {
    private func timeline(seconds: Double, replayLimit: Int = 1_000_000) -> ChannelTimeline {
        var timeline = ChannelTimeline(replayLimit: replayLimit)
        timeline.append(Audio.samples(from: 0, to: seconds))
        return timeline
    }

    @Test func keepsAtMostTheReplayLimitOfUnsettledAudio() {
        var timeline = ChannelTimeline(replayLimit: 100)
        timeline.append((0..<250).map { Int16($0) })

        #expect(timeline.received == 250)
        #expect(timeline.unsettledStart == 150)
        #expect(Array(timeline.unsettled) == (150..<250).map { Int16($0) })
    }

    @Test func aFinalSettlesTheAudioUpToItsEnd() {
        var timeline = timeline(seconds: 1)
        _ = timeline.beginStream()

        #expect(timeline.events(for: Response.final("Hello.", end: 0.5)) == [.final("Hello.", 0, 0.5)])
        #expect(timeline.settledEnd == 8_000)
        #expect(Array(timeline.unsettled) == Audio.samples(from: 0.5, to: 1))
    }

    @Test func offsetsOfALaterStreamCountFromItsReplay() {
        var timeline = timeline(seconds: 1)
        _ = timeline.beginStream()
        _ = timeline.events(for: Response.final("One.", end: 0.5))

        let replay = timeline.beginStream()
        #expect(Array(replay) == Audio.samples(from: 0.5, to: 1))
        #expect(timeline.events(for: Response.final("Two.", end: 0.25)) == [.final("Two.", 0.5, 0.75)])
    }

    @Test func voiceActivityGivesTheUtteranceStart() {
        var timeline = timeline(seconds: 2)
        _ = timeline.beginStream()

        #expect(timeline.events(for: Response.speechBegin(at: 0.3)) == [])
        #expect(timeline.events(for: Response.interim("so", end: 0.6)) == [.interim("so", 0.3, 0.6)])
        // The next utterance began before this final arrived; its start survives.
        #expect(timeline.events(for: Response.speechBegin(at: 1.2)) == [])
        #expect(timeline.events(for: Response.final("So.", end: 0.9)) == [.final("So.", 0.3, 0.9)])
        #expect(timeline.events(for: Response.final("Next.", end: 1.6)) == [.final("Next.", 1.2, 1.6)])
    }

    @Test func withoutVoiceActivityTheStartIsThePreviousFinal() {
        var timeline = timeline(seconds: 2)
        _ = timeline.beginStream()

        #expect(timeline.events(for: Response.final("One.", end: 0.5)) == [.final("One.", 0, 0.5)])
        #expect(timeline.events(for: Response.final("Two.", end: 1.5)) == [.final("Two.", 0.5, 1.5)])
    }

    @Test func joinsSeveralInterimResultsIntoOne() {
        var timeline = timeline(seconds: 1)
        _ = timeline.beginStream()

        let response = Response.results([("to be", false, 0.4), (" or not to be ", false, 0.8)])
        #expect(timeline.events(for: response) == [.interim("to be or not to be", 0, 0.8)])
    }

    @Test func anEmptyFinalClearsTheInterimOnScreen() {
        var timeline = timeline(seconds: 1)
        _ = timeline.beginStream()

        #expect(timeline.events(for: Response.final("", end: 0.2)) == [])
        _ = timeline.events(for: Response.interim("uh", end: 0.5))
        #expect(timeline.events(for: Response.final(" ", end: 0.6)) == [SpeechEvent(kind: .interim, text: "")])
        #expect(timeline.settledEnd == 9_600)
    }

    @Test func clampsOffsetsToTheAudioReceived() {
        var timeline = timeline(seconds: 1)
        _ = timeline.beginStream()

        #expect(timeline.events(for: Response.final("Late.", end: 5)) == [.final("Late.", 0, 1)])
        #expect(!timeline.hasUnsettledAudio)
    }

    @Test func aFinalWithoutAnEndOffsetSettlesNothing() {
        var timeline = timeline(seconds: 1)
        _ = timeline.beginStream()

        let events = timeline.events(for: Response.results([("Odd.", true, nil)]))
        #expect(events == [SpeechEvent(kind: .final, text: "Odd.", audioStart: 0, audioEnd: nil)])
        #expect(timeline.unsettled.count == 16_000)
    }

    @Test func isIdleUntilGoogleHearsSomething() {
        var timeline = timeline(seconds: 1)
        _ = timeline.beginStream()
        #expect(timeline.isIdle)

        _ = timeline.events(for: Response.speechBegin(at: 0.8))
        #expect(!timeline.isIdle)

        _ = timeline.events(for: Response.final("Yes.", end: 0.9))
        #expect(timeline.isIdle)

        _ = timeline.events(for: Response.interim("and", end: 1))
        #expect(!timeline.isIdle)
    }

    @Test func abandoningUnsettledAudioPromotesTheGuessOnScreen() {
        var timeline = timeline(seconds: 1)
        _ = timeline.beginStream()
        _ = timeline.events(for: Response.interim("half a", end: 0.6))

        #expect(timeline.abandonUnsettled() == [.final("half a", 0, 0.6)])
        #expect(!timeline.hasUnsettledAudio)
        #expect(timeline.settledEnd == 9_600)
        #expect(timeline.abandonUnsettled() == [])
    }

    @Test func keepNewestDropsOlderUnsettledAudio() {
        var timeline = timeline(seconds: 1)
        timeline.keepNewest(4_000)

        #expect(timeline.unsettledStart == 12_000)
        #expect(Array(timeline.beginStream()) == Audio.samples(from: 0.75, to: 1))
    }

    @Test func staysCorrectAcrossBufferCompaction() {
        var timeline = ChannelTimeline(replayLimit: 48_000)
        _ = timeline.beginStream()
        for second in 0..<10 {
            timeline.append(Audio.samples(from: Double(second), to: Double(second + 1)))
            _ = timeline.events(for: Response.final("Word.", end: Double(second) + 0.75))
        }

        #expect(timeline.received == 160_000)
        #expect(Array(timeline.unsettled) == Audio.samples(from: 9.75, to: 10))
    }
}
