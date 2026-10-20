import Foundation
import Testing

@testable import ListenerCore

struct PromptBuilderTests {
    let builder = PromptBuilder(answers: AnswerSettings())

    let turns = [
        Turn(id: 0, speaker: .me, text: "Hi, thanks for calling.", start: 1, end: 2.5),
        Turn(id: 1, speaker: .them, text: "We saw a failed copy trade on account 4471 this morning.", start: 3, end: 7),
        Turn(id: 2, speaker: .them, text: "Can you tell us why it was rejected?", start: 7.5, end: 9.8),
    ]

    @Test func quickAnswerUsesTheQuickModelAndStableSystemPrompt() {
        let first = builder.answerRequest(tier: .quick, transcript: TranscriptSnapshot(turns: turns), now: 10)
        let later = builder.answerRequest(
            tier: .quick, transcript: TranscriptSnapshot(turns: Array(turns.prefix(1)), interim: [.them: "Hello"]),
            now: 300)
        #expect(first.settings == AnswerSettings().quick)
        #expect(first.system == later.system)
        #expect(!first.cacheSystem)
        #expect(first.system.contains("British English"))
        #expect(first.system.contains("Never invent details specific to this call"))
        #expect(first.system.contains("answer the most likely reading, then add one short clarifying question"))
        #expect(first.system.contains("one to three sentences, or up to five short bullets"))
        #expect(!first.system.contains("About Me"))
    }

    @Test func deepAnswerUsesTheDeepModelAndLongerStyle() {
        let request = builder.answerRequest(tier: .deep, transcript: TranscriptSnapshot(turns: turns), now: 10)
        #expect(request.settings == AnswerSettings().deep)
        #expect(request.system.contains("thorough but easy to scan"))
        #expect(!request.system.contains("one to three sentences"))
        #expect(request.user.last?.text.hasSuffix("Take more care over this one: it may be a harder question.") == true)
    }

    @Test func contextAboutTheUserGoesIntoTheSystemPrompt() {
        var answers = AnswerSettings()
        answers.context = "  Trading Operations Engineer at Pelican, on calls with brokers.\n"
        let request = PromptBuilder(answers: answers).answerRequest(
            tier: .quick, transcript: TranscriptSnapshot(), now: 0)
        #expect(
            request.system.hasSuffix(
                "About Me, in their own words:\nTrading Operations Engineer at Pelican, on calls with brokers."))
    }

    @Test func transcriptComesBeforeTheVolatileBlock() {
        let snapshot = TranscriptSnapshot(turns: turns, interim: [.them: "and also the", .me: "  "])
        let request = builder.answerRequest(tier: .quick, transcript: snapshot, now: 75)

        #expect(request.user.count == 2)
        #expect(
            request.user[0]
                == PromptBlock(
                    """
                    <transcript>
                    [00:01] Me: Hi, thanks for calling.
                    [00:03] Them: We saw a failed copy trade on account 4471 this morning.
                    [00:07] Them: Can you tell us why it was rejected?

                    """, cacheBreakpoint: true))
        #expect(
            request.user[1]
                == PromptBlock(
                    """
                    </transcript>

                    Still being said, not final yet:
                    Them: and also the

                    It is now [01:15]. Suggest what I should say next.
                    """))
    }

    @Test func emptyTranscriptStillMakesAValidRequest() {
        let request = builder.answerRequest(tier: .quick, transcript: TranscriptSnapshot(), now: 5)
        #expect(
            request.user == [
                PromptBlock(
                    """
                    <transcript>
                    </transcript>

                    Nothing has been said yet.

                    It is now [00:05]. Suggest what I should say next.
                    """)
            ])
    }

    @Test func interimWithoutFinishedTurnsIsMarkedAsInProgress() {
        let request = builder.answerRequest(
            tier: .quick, transcript: TranscriptSnapshot(interim: [.them: "what's the cut-off\nfor today"]), now: 12)
        #expect(request.user.count == 1)
        #expect(request.user[0].text.contains("Still being said, not final yet:\nThem: what's the cut-off for today\n"))
        #expect(!request.user[0].cacheBreakpoint)
    }

    @Test func consecutiveRequestsShareTheirCachedPrefix() {
        let all = TranscriptWindowTests.conversation(120)
        let first = builder.answerRequest(
            tier: .quick, transcript: TranscriptSnapshot(turns: Array(all.prefix(100))), now: 900)
        let second = builder.answerRequest(
            tier: .quick, transcript: TranscriptSnapshot(turns: all, interim: [.them: "so"]), now: 960)

        let breakpoints = first.user.indices.filter { first.user[$0].cacheBreakpoint }
        #expect(breakpoints.count == 2)
        #expect(breakpoints.last == first.user.count - 2)
        // Everything up to the first request's last complete block comes back byte for
        // byte, so the next request reads it from the cache. Markers may move; text may not.
        let completeBlock = breakpoints[0]
        #expect(second.user.prefix(completeBlock + 1).map(\.text) == first.user.prefix(completeBlock + 1).map(\.text))
        #expect(second.user.count > first.user.count)
        #expect(first.system == second.system)
        #expect(second.user.filter(\.cacheBreakpoint).count == 2)
        #expect(!second.user.last!.cacheBreakpoint)
    }

    @Test func omittedEarlierTurnsAreFlagged() {
        var answers = AnswerSettings()
        answers.transcriptBudgetTokens = 1_000
        let request = PromptBuilder(answers: answers).answerRequest(
            tier: .quick, transcript: TranscriptSnapshot(turns: TranscriptWindowTests.conversation(200)), now: 0)
        #expect(request.user[0].text.hasPrefix("<transcript>\n[Earlier parts of the call are not shown.]\n["))
    }

    @Test func summaryHasTitleTranscriptAndStructure() {
        var settings = SummarySettings()
        settings.model.maxTokens = 5_000
        let request = builder.summaryRequest(
            turns: turns, settings: settings, startedAt: Date(timeIntervalSince1970: 1_792_505_100), duration: 1_920,
            timeZone: TimeZone(identifier: "UTC")!)

        #expect(request.settings == settings.model)
        #expect(request.user.count == 1)
        #expect(
            request.user[0].text == """
                Title line: # Call on Tuesday 20 October 2026 at 14:05 (32 min)

                <transcript>
                [00:01] Me: Hi, thanks for calling.
                [00:03] Them: We saw a failed copy trade on account 4471 this morning.
                [00:07] Them: Can you tell us why it was rejected?
                </transcript>

                Write the notes.
                """)
        for heading in ["## Summary", "## Decisions", "## Action items", "## Open questions", "## Follow-up email"] {
            #expect(request.system.contains(heading))
        }
        #expect(request.system.contains("only when a deadline was actually stated on the call"))
        #expect(request.system.contains("Never invent amounts, account or ticket numbers, dates"))
        #expect(request.system.contains("British English"))
    }

    @Test func summaryDurationDefaultsToTheLastTurn() {
        let request = builder.summaryRequest(
            turns: turns, settings: SummarySettings(), startedAt: Date(timeIntervalSince1970: 1_792_505_100),
            timeZone: TimeZone(identifier: "UTC")!)
        #expect(
            request.user[0].text.hasPrefix("Title line: # Call on Tuesday 20 October 2026 at 14:05 (under a minute)"))
    }

    @Test func summaryOfAnEmptyCallSaysSo() {
        let request = builder.summaryRequest(turns: [], settings: SummarySettings())
        #expect(
            request.user[0].text.hasSuffix("</transcript>\n\nNothing was transcribed on this call. Write the notes."))
    }

    @Test func summaryKeepsTheNewestTurnsUnderItsCap() {
        let all = TranscriptWindowTests.conversation(300)
        let request = builder.summaryRequest(turns: all, settings: SummarySettings(), maxTranscriptTokens: 2_000)
        let text = request.user[0].text
        #expect(text.contains("<transcript>\n[Earlier parts of the call are not shown.]\n"))
        #expect(text.contains(TranscriptWindow.line(for: all[299])))
        #expect(!text.contains(TranscriptWindow.line(for: all[0])))
    }

    @Test func durationsReadNaturally() {
        #expect(PromptBuilder.durationText(20) == "under a minute")
        #expect(PromptBuilder.durationText(1_920) == "32 min")
        #expect(PromptBuilder.durationText(3_900) == "1 h 5 min")
    }
}
