import Foundation
import Testing

@testable import ListenerCore

struct CallViewStateTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private let channels = [
        ChannelInfo(speaker: .me, backend: "AVAudioEngine", device: "Headset", nativeFormat: "48 kHz"),
        ChannelInfo(speaker: .them, backend: "Core Audio process tap", device: "all system audio", nativeFormat: ""),
    ]

    @Test func startingAndListening() {
        var state = CallViewState()
        #expect(state.canStart && !state.canStop && !state.canAsk)

        state.beginStarting()
        #expect(state.phase == .starting)
        #expect(state.isBusy && !state.canStart)

        state.apply(.started(channels: channels), now: start)
        #expect(state.phase == .listening)
        #expect(state.listeningSince == start)
        #expect(state.channels == channels)
        #expect(state.canStop && state.canAsk && !state.canStart)
    }

    @Test func failedStartGoesBackToIdleWithAnError() {
        var state = CallViewState()
        state.beginStarting()
        state.startFailed("Microphone access is denied.")
        #expect(state.phase == .idle)
        #expect(state.notices.map(\.message) == ["Microphone access is denied."])
        #expect(state.notices.first?.kind == .error)
    }

    @Test func rowsGroupConsecutiveTurnsBySpeaker() {
        var state = listening()
        state.apply(
            .transcript(
                TranscriptSnapshot(turns: [
                    Turn(id: 1, speaker: .them, text: "Hi, it's the dealing desk.", start: 1, end: 3),
                    Turn(id: 2, speaker: .them, text: "About the EURUSD fills.", start: 4, end: 6),
                    Turn(id: 3, speaker: .me, text: "Sure, go ahead.", start: 7, end: 8),
                ])), now: start)

        #expect(state.rows.map(\.id) == [.turn(1), .turn(2), .turn(3)])
        #expect(state.rows.map(\.showsSpeaker) == [true, false, true])
        #expect(state.rows.map(\.start) == [1, 4, 7])
        #expect(state.rows.allSatisfy { !$0.isInterim })
    }

    @Test func interimRowsFollowTheTurnsInTheOrderPeopleStartedSpeaking() {
        var state = listening()
        let turns = [Turn(id: 1, speaker: .me, text: "Hello.", start: 0, end: 1)]
        state.apply(.transcript(TranscriptSnapshot(turns: turns, interim: [.them: "we saw"])), now: start)
        state.apply(
            .transcript(TranscriptSnapshot(turns: turns, interim: [.them: "we saw a gap", .me: "right"])), now: start)

        #expect(state.rows.map(\.id) == [.turn(1), .interim(.them), .interim(.me)])
        #expect(state.rows.map(\.text) == ["Hello.", "we saw a gap", "right"])
        #expect(state.rows.map(\.isInterim) == [false, true, true])
        #expect(state.rows.map(\.showsSpeaker) == [true, true, true])

        state.apply(.transcript(TranscriptSnapshot(turns: turns, interim: [.them: "  ", .me: "right so"])), now: start)
        #expect(state.rows.map(\.id) == [.turn(1), .interim(.me)])
        #expect(state.rows.last?.showsSpeaker == false)
    }

    @Test func answerStreamsAndFinishesWithTheSessionsNumbers() {
        var state = listening()
        state.apply(.answerStarted(id: 1, tier: .quick, model: "claude-haiku-5-5"), now: start)
        #expect(state.answer?.status == .waiting)
        #expect(state.answer?.isActive == true)

        state.apply(.answerText(id: 1, delta: "Ask them for"), now: start.addingTimeInterval(0.5))
        state.apply(.answerText(id: 1, delta: " the order ID."), now: start.addingTimeInterval(0.9))
        #expect(state.answer?.text == "Ask them for the order ID.")
        #expect(state.answer?.status == .streaming)
        #expect(state.answer?.firstTokenMs == 500)

        var record = AnswerRecord(
            id: 1, tier: .quick, model: "claude-haiku-5-5", askedAt: 12, text: "Ask them for the order ID.",
            cost: 0.0004)
        record.latency.hotkeyToFirstToken = 640
        state.apply(.answerFinished(record), now: start)
        #expect(state.answer?.status == .finished)
        #expect(state.answer?.firstTokenMs == 640)
        #expect(state.answer?.cost == 0.0004)
        #expect(state.lastLatencyMs == 640)
        #expect(state.dismissAnswer() == nil)
        #expect(state.answer == nil)
    }

    @Test func eventsForAnOldAnswerAreIgnored() {
        var state = listening()
        state.apply(.answerStarted(id: 1, tier: .quick, model: "haiku"), now: start)
        state.apply(.answerStarted(id: 2, tier: .deep, model: "sonnet"), now: start)
        state.apply(.answerText(id: 1, delta: "stale"), now: start)
        state.apply(.answerFailed(id: 1, message: "Cancelled"), now: start)
        #expect(state.answer?.id == 2)
        #expect(state.answer?.text == "")
        #expect(state.answer?.status == .waiting)
    }

    @Test func dismissingAStreamingAnswerReturnsItsIDForCancelling() {
        var state = listening()
        state.apply(.answerStarted(id: 4, tier: .deep, model: "sonnet"), now: start)
        state.apply(.answerText(id: 4, delta: "Partly"), now: start)
        #expect(state.dismissAnswer() == 4)
        state.apply(.answerFailed(id: 4, message: "Cancelled"), now: start)
        #expect(state.answer == nil)
    }

    @Test func failedAnswersShowTheError() {
        var state = listening()
        state.apply(.answerStarted(id: 1, tier: .quick, model: "haiku"), now: start)
        state.apply(.answerFailed(id: 1, message: "Anthropic API: overloaded"), now: start)
        #expect(state.answer?.status == .failed("Anthropic API: overloaded"))

        state.apply(.answerStarted(id: 2, tier: .quick, model: "haiku"), now: start)
        state.apply(
            .answerFinished(AnswerRecord(id: 2, tier: .quick, model: "haiku", askedAt: 0, error: "Timed out")),
            now: start)
        #expect(state.answer?.status == .failed("Timed out"))
        #expect(state.lastLatencyMs == nil)
    }

    @Test func warningsAreDeduplicatedAndCapped() {
        var state = listening()
        state.apply(.warning("Them is silent"), now: start)
        state.apply(.warning("Them is silent"), now: start)
        #expect(state.notices.count == 1)

        for index in 1...4 {
            state.apply(.warning("Warning \(index)"), now: start)
        }
        #expect(state.notices.map(\.message) == ["Warning 2", "Warning 3", "Warning 4"])
        #expect(Set(state.notices.map(\.id)).count == 3)

        let id = state.notices[0].id
        state.dismissNotice(id: id)
        #expect(state.notices.map(\.message) == ["Warning 3", "Warning 4"])
    }

    @Test func stoppingSummarisingAndSaving() {
        var state = listening()
        state.apply(.transcript(TranscriptSnapshot(turns: [], interim: [.me: "and"])), now: start)
        state.apply(.cost(CostSummary(speechCost: 0.12, modelCost: 0.01)), now: start)
        #expect(state.cost.total == 0.13)

        state.beginStopping()
        #expect(state.phase == .stopping)
        state.apply(.summaryStarted, now: start)
        #expect(state.phase == .summarizing)
        state.apply(.summaryFinished(markdownFile: "/s/2026-10-20 14.03.11/summary.md"), now: start)
        state.apply(.stopped(directory: "/s/2026-10-20 14.03.11"), now: start)

        #expect(state.phase == .finished)
        #expect(state.canStart)
        #expect(state.listeningSince == nil)
        #expect(state.rows.isEmpty)
        #expect(state.sessionDirectory == "/s/2026-10-20 14.03.11")
        #expect(state.notices.isEmpty)
        #expect(
            state.outcome
                == CallOutcome(
                    directory: "/s/2026-10-20 14.03.11", summaryFile: "/s/2026-10-20 14.03.11/summary.md",
                    duration: 0, turnCount: 0, cost: 0.13))
    }

    @Test func theOutcomeHasTheCallsLengthTurnsAndCost() {
        var state = listening()
        let turns = [
            Turn(id: 1, speaker: .them, text: "Hello.", start: 0, end: 1),
            Turn(id: 2, speaker: .me, text: "Hi.", start: 2, end: 3),
        ]
        state.apply(.transcript(TranscriptSnapshot(turns: turns)), now: start)
        state.apply(.cost(CostSummary(speechCost: 0.1, modelCost: 0.02)), now: start)
        state.apply(.stopped(directory: "/s/call"), now: start.addingTimeInterval(725))

        #expect(state.outcome?.summaryFile == nil)
        #expect(state.outcome?.details == "12:05 · 2 turns · $0.12")
        #expect(state.rows.map(\.text) == ["Hello.", "Hi."])

        state.clearFinishedCall()
        #expect(state.phase == .idle && state.outcome == nil && state.rows.isEmpty)
    }

    @Test func aSummaryAfterStoppingReachesTheOutcome() {
        var state = listening()
        state.apply(.stopped(directory: "/s/call"), now: start)
        state.apply(.summaryStarted, now: start)
        #expect(state.phase == .finished)
        state.apply(.summaryFinished(markdownFile: "/s/call/summary.md"), now: start)
        #expect(state.outcome?.summaryFile == "/s/call/summary.md")
    }

    @Test func failedSaveIsAnError() {
        var state = listening()
        state.apply(.stopped(directory: nil), now: start)
        #expect(state.notices.last?.kind == .error)
        #expect(state.outcome == nil)
    }

    @Test func interimUpdatesLeaveTheSettledRowsAlone() {
        var state = listening()
        let turns = [Turn(id: 1, speaker: .them, text: "We saw a gap.", start: 0, end: 2)]
        state.apply(.transcript(TranscriptSnapshot(turns: turns, interim: [.them: "and"])), now: start)
        let settled = state.settledRows
        state.apply(.transcript(TranscriptSnapshot(turns: turns, interim: [.them: "and then"])), now: start)

        #expect(state.settledRows == settled)
        #expect(state.liveRows.map(\.text) == ["and then"])
        #expect(state.liveRows.first?.showsSpeaker == false)

        state.apply(.transcript(TranscriptSnapshot(turns: turns, interim: [.me: "right"])), now: start)
        #expect(state.liveRows.first?.showsSpeaker == true)
    }

    @Test func channelActivityIsUnknownUntilReported() {
        var state = listening()
        #expect(state.hearing == nil)
        state.channelActivity(.them, isSpeaking: true)
        state.channelActivity(.me, isSpeaking: true)
        state.channelActivity(.me, isSpeaking: false)
        #expect(state.hearing == [.them])

        state.apply(.stopped(directory: "/s/call"), now: start)
        #expect(state.hearing == nil)
    }

    @Test func channelActivityEventsReachTheHearingChips() {
        var state = listening()
        state.apply(.channelActivity(.them, isSpeaking: true), now: start)
        #expect(state.hearing == [.them])
        state.apply(.channelActivity(.them, isSpeaking: false), now: start)
        #expect(state.hearing == [])
    }

    @Test func captureEventsBecomeBanners() {
        var state = listening()
        state.apply(.restarted(.them, reason: .outputDeviceChanged))
        state.apply(.stoppedByUser(.them))
        #expect(state.notices.map(\.kind) == [.info, .warning])
        #expect(state.notices[0].message == "Them: capture restarted (output device changed).")
    }

    @Test func eventsEndingWithoutAStopFinishTheCall() {
        var state = listening()
        state.eventsEnded()
        #expect(state.phase == .finished)
        #expect(state.notices.last?.message == "The call could not be saved.")

        var idle = CallViewState()
        idle.eventsEnded()
        #expect(idle.phase == .idle)
        #expect(idle.notices.isEmpty)
    }

    @Test func startingAgainClearsThePreviousCall() {
        var state = listening()
        state.apply(
            .transcript(TranscriptSnapshot(turns: [Turn(id: 1, speaker: .me, text: "x", start: 0, end: 1)])), now: start
        )
        state.apply(.stopped(directory: "/s/call"), now: start)
        state.beginStarting()
        #expect(state.rows.isEmpty)
        #expect(state.notices.isEmpty)
        #expect(state.sessionDirectory == nil)
        #expect(state.phase == .starting)
    }

    private func listening() -> CallViewState {
        var state = CallViewState()
        state.beginStarting()
        state.apply(.started(channels: channels), now: start)
        return state
    }
}
