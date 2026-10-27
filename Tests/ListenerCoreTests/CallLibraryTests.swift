import Foundation
import Testing

@testable import ListenerCore

final class CallLibraryTests {
    private let root: URL
    private let start = Date(timeIntervalSince1970: 1_792_505_100)

    init() throws {
        root = try temporaryDirectory("calls")
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// A call that ended cleanly, saved the way CallSession saves one.
    @discardableResult
    private func savedCall(
        startingAfter minutes: Double, turns: [Turn], answers: [AnswerRecord] = [], summary: String? = nil,
        cost: Double = 0, callType: String = "", summaryDue: Bool = false
    ) throws -> URL {
        let startedAt = start.addingTimeInterval(minutes * 60)
        let store = try SessionStore(root: root, startedAt: startedAt)
        for turn in turns {
            try store.append(turn)
        }
        for answer in answers {
            try store.append(answer)
        }
        try store.write(
            SessionRecord(
                startedAt: startedAt, endedAt: startedAt.addingTimeInterval(65), channels: [], speechProvider: "x",
                settings: Settings(), turnCount: turns.count, answers: answers, cost: CostSummary(speechCost: cost),
                summaryDue: summaryDue, call: CallContext(callType: callType, instructions: "", documents: [])))
        if let summary {
            try store.writeSummary(summary)
        }
        try store.close()
        return store.directory
    }

    private let brokerTurns = [
        Turn(id: 1, speaker: .them, text: "Hi, it's Hannah at Kestrelmoor Markets.", start: 0.8, end: 6.4),
        Turn(id: 2, speaker: .me, text: "Hi Hannah, go ahead.", start: 7.3, end: 8.4),
        Turn(
            id: 3, speaker: .me, text: "Volume at the open hit six times normal at Kestrelmoor.", start: 15.9, end: 20.9
        ),
    ]

    private let answers = [
        AnswerRecord(id: 1, tier: .quick, model: "claude-haiku-5-5", askedAt: 9, text: "Ask which accounts."),
        AnswerRecord(id: 2, tier: .deep, model: "claude-sonnet-5-5", askedAt: 21, text: "We saw it too."),
    ]

    @Test func listsCallsNewestFirst() throws {
        try savedCall(
            startingAfter: 0, turns: brokerTurns, answers: answers, summary: CallSummaryTests.notes, cost: 0.25,
            callType: "Broker call")
        try savedCall(
            startingAfter: 10, turns: [brokerTurns[0]],
            summary: "# Call on Tuesday 20 October 2026 at 14:15 (1 min)\n\n## Action items\n- [x] **Me**: done")
        try savedCall(startingAfter: 20, turns: [brokerTurns[0]], summaryDue: true)

        // The app died mid-call: session.json is as written at Start, the files say more.
        let crashedAt = start.addingTimeInterval(30 * 60)
        let crashed = try SessionStore(root: root, startedAt: crashedAt)
        try crashed.write(SessionRecord(startedAt: crashedAt, channels: [], speechProvider: "x", settings: Settings()))
        try crashed.append(brokerTurns[0])
        try crashed.append(brokerTurns[1])
        try crashed.append(answers[0])
        try crashed.close()

        let calls = CallLibrary.calls(in: root)
        #expect(
            calls.map(\.startedAt.timeIntervalSince1970)
                == [30, 20, 10, 0].map { start.timeIntervalSince1970 + $0 * 60 })

        #expect(calls[0].duration == nil && calls[0].turnCount == 2 && calls[0].answerCount == 1)
        #expect(calls[0].cost == CostSummary() && !calls[0].hasSummary && !calls[0].summaryDue)

        #expect(calls[1].summaryDue && !calls[1].hasSummary && calls[1].title == nil)

        #expect(calls[2].hasSummary && calls[2].title == nil && calls[2].myOpenActionItems == 0)

        let broker = calls[3]
        #expect(broker.title == "Kestrelmoor Markets: delayed copy trades after the US open")
        #expect(broker.duration == 65 && broker.turnCount == 3 && broker.answerCount == 2)
        #expect(broker.cost?.total == 0.25 && broker.callType == "Broker call")
        #expect(broker.hasSummary && !broker.summaryDue && broker.myOpenActionItems == 2)
        #expect(broker.id == broker.directory)

        #expect(CallLibrary.calls(in: root.appendingPathComponent("missing")).isEmpty)
    }

    @Test func aCallInFull() throws {
        try savedCall(startingAfter: 0, turns: brokerTurns, answers: answers, summary: CallSummaryTests.notes)
        let listed = try #require(CallLibrary.calls(in: root).first)
        let detail = try CallLibrary.detail(in: listed.directory)
        #expect(detail.call == listed)
        #expect(detail.turns == brokerTurns)
        #expect(detail.answers == answers)
        #expect(detail.summaryMarkdown == CallSummaryTests.notes + "\n")
        #expect(detail.summary == CallSummary(markdown: CallSummaryTests.notes))
        #expect(near(detail.talkTime[.them], 5.6, within: 1e-6) && near(detail.talkTime[.me], 6.1, within: 1e-6))

        let bare = try savedCall(startingAfter: 5, turns: [])
        let empty = try CallLibrary.detail(in: bare)
        #expect(empty.summary == nil && empty.summaryMarkdown == nil && empty.talkTime.isEmpty)
        #expect(throws: (any Error).self) { try CallLibrary.detail(in: self.root.appendingPathComponent("gone")) }
    }

    @Test func tickingAnActionItemRewritesTheSummary() throws {
        let directory = try savedCall(startingAfter: 0, turns: brokerTurns, summary: CallSummaryTests.notes)
        let item = try #require(CallLibrary.detail(in: directory).summary?.actionItems.first)

        let summary = try CallLibrary.setDone(true, for: item, in: directory)
        #expect(summary.actionItems.map(\.done) == [true, true, false])
        let file = try String(contentsOf: directory.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(file == CallSummaryTests.notes.replacingOccurrences(of: "- [ ] **Me**", with: "- [x] **Me**") + "\n")
        #expect(CallLibrary.calls(in: root).first?.myOpenActionItems == 1)

        var gone = item
        gone.text = "something never written"
        #expect(throws: CallLibraryError.actionItemNotFound) { try CallLibrary.setDone(true, for: gone, in: directory) }
    }

    @Test func searchFindsCallsWithEveryWord() throws {
        try savedCall(startingAfter: 0, turns: brokerTurns, summary: CallSummaryTests.notes)
        try savedCall(
            startingAfter: 10,
            turns: [
                Turn(id: 1, speaker: .them, text: "Morning.", start: 0, end: 1),
                Turn(id: 2, speaker: .them, text: "Zoë asked about the café rebate. Zoe again.", start: 42, end: 45),
            ])
        let calls = CallLibrary.calls(in: root)
        let index = CallSearchIndex(calls: calls)

        let broker = index.search("volume KESTRELMOOR")
        #expect(broker.map(\.call) == [calls[1]])
        let snippet = try #require(broker.first?.snippet)
        #expect(snippet.speaker == .me && snippet.start == 15.9 && snippet.text == brokerTurns[2].text)
        #expect(snippet.matches.map { String(snippet.text[$0]) } == ["Volume", "Kestrelmoor"])

        let rebate = try #require(index.search("zoe CAFÉ").first)
        #expect(rebate.call == calls[0] && rebate.snippet?.start == 42)
        #expect(
            rebate.snippet.map { snippet in snippet.matches.map { String(snippet.text[$0]) } } == [
                "Zoë", "café", "Zoe",
            ])

        // Words can be in different parts of the call, but all must be in the same call.
        let acrossParts = index.search("slippage hannah")
        #expect(acrossParts.map(\.call) == [calls[1]])
        #expect(acrossParts.first?.snippet?.text == brokerTurns[0].text)
        #expect(index.search("slippage").first?.snippet == nil)
        #expect(index.search("kestrelmoor rebate").isEmpty)
        #expect(index.search("  ").isEmpty)

        let overlapping = try #require(index.search("kest kestrel").first?.snippet)
        #expect(overlapping.matches.map { String(overlapping.text[$0]) } == ["Kestrel"])
    }

    @Test func costThisMonthCountsOnlyThisMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        func call(_ month: Int, _ day: Int, cost: Double?) -> SavedCall {
            SavedCall(
                directory: URL(fileURLWithPath: "/calls/\(month)-\(day)"),
                startedAt: calendar.date(
                    from: DateComponents(year: 2026, month: month, day: day, hour: 0, minute: 30))!,
                duration: 60, turnCount: 1, cost: cost.map { CostSummary(speechCost: $0, modelCost: 0.01) },
                callType: nil, title: nil, hasSummary: false, summaryDue: false, myOpenActionItems: 0, answerCount: 0)
        }
        let calls = [
            call(11, 1, cost: 4), call(10, 31, cost: 0.5), call(10, 1, cost: 0.25), call(10, 2, cost: nil),
            call(9, 30, cost: 8),
        ]
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!
        #expect(near(CallLibrary.costThisMonth(of: calls, now: now, calendar: calendar), 0.77))
    }
}
