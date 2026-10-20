import Testing

@testable import ListenerCore

struct LatencyStatsTests {
    @Test func percentilesInterpolateBetweenRanks() throws {
        let stats = try #require(LatencyStats.Percentiles([400, 100, 300, 200, 1_000]))
        #expect(stats.count == 5)
        #expect(stats.p50 == 300)
        #expect(abs(stats.p90 - 760) < 1e-9)
        #expect(LatencyStats.Percentiles([42]) == LatencyStats.Percentiles(count: 1, p50: 42, p90: 42))
        #expect(LatencyStats.Percentiles([]) == nil)
    }

    @Test func eachStageIsSummarisedOverTheAnswersThatMeasuredIt() {
        var first = AnswerLatency()
        first.hotkeyToFirstToken = 400
        first.endOfSpeechToFirstToken = 1_200
        var second = AnswerLatency()
        second.hotkeyToFirstToken = 600
        let stats = LatencyStats([first, second, AnswerLatency()])
        #expect(stats.hotkeyToFirstToken == LatencyStats.Percentiles(count: 2, p50: 500, p90: 580))
        #expect(stats.endOfSpeechToFirstToken?.count == 1)
        #expect(stats.endOfSpeechToHotkey == nil)
        #expect(stats.finalToHotkey == nil)
    }
}

struct SpeechTimelineTests {
    @Test func endOfSpeechPrefersThemThenMe() {
        var timeline = SpeechTimeline()
        #expect(timeline.endOfSpeech() == nil)
        timeline.speechStarted(.me, at: 1)
        timeline.speechEnded(.me, at: 2)
        #expect(timeline.endOfSpeech()?.end == 2)
        timeline.speechStarted(.them, at: 3)
        // Them is still talking: the last finished speech is still Me's.
        #expect(timeline.endOfSpeech()?.speaker == .me)
        timeline.speechEnded(.them, at: 4)
        timeline.speechStarted(.me, at: 5)
        timeline.speechEnded(.me, at: 6)
        #expect(timeline.endOfSpeech()?.speaker == .them)
        #expect(timeline.endOfSpeech()?.end == 4)
    }

    @Test func finalsMarkTheSpeechTheyCover() {
        var timeline = SpeechTimeline()
        timeline.speechStarted(.them, at: 1)
        timeline.speechEnded(.them, at: 2)
        timeline.speechStarted(.them, at: 3)
        timeline.speechEnded(.them, at: 4)
        timeline.speechStarted(.me, at: 4.5)
        timeline.speechEnded(.me, at: 5)

        // The recogniser put the end of the words at 1.8 s; the detector heard to 2.0 s.
        let first = timeline.finalArrived(.them, audioEnd: 1.8, at: 2.4)
        #expect(first.count == 1)
        #expect(timeline.segments.first?.finalAt == 2.4)
        #expect(timeline.endOfSpeech()?.finalAt == nil)

        let second = timeline.finalArrived(.them, audioEnd: nil, at: 4.3)
        #expect(second.count == 1)
        #expect(timeline.endOfSpeech()?.finalAt == 4.3)
        #expect(timeline.segments.last?.finalAt == nil)
    }

    @Test func keepsARecentWindow() {
        var timeline = SpeechTimeline()
        for index in 0..<100 {
            timeline.speechStarted(.me, at: Double(index))
            timeline.speechEnded(.me, at: Double(index) + 0.5)
        }
        #expect(timeline.segments.count == 64)
        #expect(timeline.endOfSpeech()?.end == 99.5)
    }
}
