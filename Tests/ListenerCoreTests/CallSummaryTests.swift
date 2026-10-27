import Testing

@testable import ListenerCore

struct CallSummaryTests {
    static let notes = """
        # Kestrelmoor Markets: delayed copy trades after the US open
        *Tuesday 27 October 2026 at 14:45, 1 min*

        ## Summary
        - Hannah at Kestrelmoor Markets called about a flood of complaints since the US open.
        - Volume at the open hit **six times** normal and backed up the follower order queue.

        ## Decisions
        None recorded.

        ## Action items
        - [ ] **Me**: send Hannah the affected accounts (due this afternoon)
        - [x] **Them:** forward the complaints with account numbers
        - [ ] check with client services about the slippage

        ## Open questions
        - Will Pelican cover the slippage on the late fills?

        ## Follow-up email
        Subject: INC-4471: delayed copy trades after the US open

        Hi Hannah,

        Thanks for the call. I'll send the **list** this afternoon.

        Best regards,
        [name]
        """

    @Test func readsEverySection() {
        let summary = CallSummary(markdown: Self.notes)
        #expect(summary.title == "Kestrelmoor Markets: delayed copy trades after the US open")
        #expect(summary.dateLine == "Tuesday 27 October 2026 at 14:45, 1 min")
        #expect(
            summary.summary == [
                "Hannah at Kestrelmoor Markets called about a flood of complaints since the US open.",
                "Volume at the open hit **six times** normal and backed up the follower order queue.",
            ])
        #expect(summary.decisions.isEmpty)
        #expect(
            summary.actionItems == [
                .init(
                    done: false, owner: "Me", text: "send Hannah the affected accounts (due this afternoon)", line: 11),
                .init(done: true, owner: "Them", text: "forward the complaints with account numbers", line: 12),
                .init(done: false, owner: nil, text: "check with client services about the slippage", line: 13),
            ])
        #expect(summary.openQuestions == ["Will Pelican cover the slippage on the late fills?"])
        #expect(summary.email?.subject == "INC-4471: delayed copy trades after the US open")
        #expect(
            summary.email?.body
                == "Hi Hannah,\n\nThanks for the call. I'll send the **list** this afternoon.\n\nBest regards,\n[name]")
        #expect(
            summary.email?.text == """
                Subject: INC-4471: delayed copy trades after the US open

                Hi Hannah,

                Thanks for the call. I'll send the list this afternoon.

                Best regards,
                [name]
                """)
        #expect(summary.other.isEmpty)
        #expect(!summary.cutShort)
    }

    @Test func anOlderSummaryIsTitledByItsDate() {
        let summary = CallSummary(
            markdown: "# Call on Monday 26 October 2026 at 08:33 (1 min)\n\n## Summary\n- Short call.\n")
        #expect(summary.title == nil)
        #expect(summary.dateLine == "Call on Monday 26 October 2026 at 08:33 (1 min)")
        #expect(summary.summary == ["Short call."])
        #expect(summary.other.isEmpty)
    }

    @Test func takesWhatModelsActuallyWrite() {
        let summary = CallSummary(
            markdown: """
                Here are the notes.

                ### Kestrelmoor Markets: delayed executions

                Tuesday 27 October 2026 at 14:45, 1 min


                ### Action Items:
                1. [X] **Me** - pull the account list
                2) [ ] **Hannah (Kestrelmoor):** confirm the
                   compliance deadline
                [ ] Me: email the incident reference

                **Summary**
                * Copy trades reached followers late.
                + Delays are under a second now.
                Since the workers were scaled out.

                ---

                ## Risks
                Another spike at **tomorrow's** open.

                ## Open questions
                - *None.*

                ## Follow-up e-mail
                ```
                **Subject:** Delays at the open
                Hi Hannah,
                Thanks.
                ```
                """)
        #expect(summary.title == "Kestrelmoor Markets: delayed executions")
        #expect(summary.dateLine == "Tuesday 27 October 2026 at 14:45, 1 min")
        #expect(
            summary.actionItems == [
                .init(done: true, owner: "Me", text: "pull the account list", line: 8),
                .init(done: false, owner: "Hannah (Kestrelmoor)", text: "confirm the compliance deadline", line: 9),
                .init(done: false, owner: "Me", text: "email the incident reference", line: 11),
            ])
        #expect(
            summary.summary == [
                "Copy trades reached followers late.",
                "Delays are under a second now. Since the workers were scaled out.",
            ])
        #expect(summary.openQuestions.isEmpty)
        #expect(summary.email == CallSummary.Email(subject: "Delays at the open", body: "Hi Hannah,\nThanks."))
        #expect(
            summary.other == [
                .init(heading: "", text: "Here are the notes."),
                .init(heading: "Risks", text: "Another spike at **tomorrow's** open."),
            ])
    }

    @Test func notesWithoutBulletsKeepTheirParagraphs() {
        let summary = CallSummary(
            markdown: """
                ## Summary
                The broker asked why copy trades were late.
                It was the queue.

                They accepted the fix.

                ## Decisions
                - None

                ## Follow-up email
                None.
                """)
        #expect(summary.title == nil && summary.dateLine == nil)
        #expect(
            summary.summary == [
                "The broker asked why copy trades were late. It was the queue.", "They accepted the fix.",
            ])
        #expect(summary.decisions.isEmpty)
        #expect(summary.email == nil)
    }

    @Test func aSummaryCutShortSaysSo() {
        let summary = CallSummary(markdown: "## Summary\n- The report\n\n" + SessionSummarizer.cutShortNote + "\n")
        #expect(summary.cutShort)
        #expect(summary.summary == ["The report"])
        #expect(summary.other.isEmpty)
    }

    @Test func countsOnlyYourOpenActionItems() {
        let summary = CallSummary(
            markdown: """
                ## Action items
                - [ ] **Me**: send the fill report
                - [x] **Me**: book the follow-up
                - [ ] **Them**: confirm the margin change
                - [ ] **Hannah**: forward the complaints
                - [ ] **Me and Them**: agree the cut-over date
                - [ ] **Both**: sign off the runbook
                - [ ] check the slippage
                """)
        #expect(summary.actionItems.map(\.isMine) == [true, true, false, false, true, true, true])
        #expect(summary.myOpenActionItems == 4)
        #expect(CallSummary(markdown: Self.notes).myOpenActionItems == 2)
    }

    @Test func tickingChangesOnlyTheCheckbox() throws {
        let summary = CallSummary(markdown: Self.notes)
        let ticked = try #require(CallSummary.setting(summary.actionItems[0], done: true, in: Self.notes))
        #expect(
            ticked
                == Self.notes.replacingOccurrences(
                    of: "- [ ] **Me**: send Hannah", with: "- [x] **Me**: send Hannah"))
        #expect(CallSummary(markdown: ticked).actionItems.map(\.done) == [true, true, false])

        let unticked = try #require(CallSummary.setting(summary.actionItems[1], done: false, in: ticked))
        #expect(CallSummary(markdown: unticked).actionItems.map(\.done) == [true, false, false])
        #expect(CallSummary.setting(summary.actionItems[1], done: true, in: Self.notes) == Self.notes)
    }

    @Test func anItemWithoutACheckboxGetsOne() throws {
        let markdown = "## Action items\r\n\r\n  - Send the fill report.\r\n"
        let item = try #require(CallSummary(markdown: markdown).actionItems.first)
        #expect(item == .init(done: false, owner: nil, text: "Send the fill report.", line: 2))
        #expect(
            CallSummary.setting(item, done: true, in: markdown)
                == "## Action items\r\n\r\n  - [x] Send the fill report.\r\n")
    }

    @Test func tickingFindsAnItemThatMoved() throws {
        let item = CallSummary(markdown: Self.notes).actionItems[2]
        let edited = Self.notes.replacingOccurrences(
            of: "## Action items\n", with: "## Action items\n\nAdded by hand.\n")
        let ticked = try #require(CallSummary.setting(item, done: true, in: edited))
        #expect(ticked.contains("- [x] check with client services about the slippage"))

        let rewritten = Self.notes.replacingOccurrences(of: "check with client services", with: "ask client services")
        #expect(CallSummary.setting(item, done: true, in: rewritten) == nil)
    }
}
