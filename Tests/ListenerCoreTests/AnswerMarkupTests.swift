import Testing

@testable import ListenerCore

struct AnswerMarkupTests {
    @Test func plainSentencesAreOneParagraphPerLine() {
        let markup = AnswerMarkup("I'll check the fills and call you back.\n\nIs that all right?")
        #expect(markup.blocks.map(\.kind) == [.paragraph, .paragraph])
        #expect(markup.blocks.map(\.text) == ["I'll check the fills and call you back.", "Is that all right?"])
        #expect(markup.blocks.map(\.id) == [0, 1])
    }

    @Test func listsKeepTheirMarkers() {
        let markup = AnswerMarkup("Two options:\n- Re-run the copy job\n* Wait for the fix\n2. Call Dealing\n3) Log it")
        #expect(markup.blocks.map(\.kind) == [.paragraph, .bullet("•"), .bullet("•"), .bullet("2."), .bullet("3.")])
        #expect(markup.blocks[1].text == "Re-run the copy job")
        #expect(markup.blocks[4].text == "Log it")
    }

    @Test func boldRunsAreMarked() {
        let markup = AnswerMarkup("- **Today:** I'll send the list.")
        #expect(markup.blocks[0].spans == [AnswerSpan("Today:", .bold), AnswerSpan(" I'll send the list.")])
    }

    @Test func aBracketedLineIsANoteWithoutItsBrackets() {
        let markup = AnswerMarkup("I'll confirm and come back to you.\n[No cause is confirmed yet.]")
        #expect(markup.blocks[1].kind == .note)
        #expect(markup.blocks[1].spans == [AnswerSpan("No cause is confirmed yet.", .note)])
    }

    @Test func notesInsideASentenceStayInline() {
        let markup = AnswerMarkup("We can refund the fees [check the schedule] once it's reviewed.")
        #expect(markup.blocks[0].kind == .paragraph)
        #expect(
            markup.blocks[0].spans == [
                AnswerSpan("We can refund the fees "), AnswerSpan("check the schedule", .note),
                AnswerSpan(" once it's reviewed."),
            ])
    }

    @Test func linksKeepTheirTextAndDropTheAddress() {
        let markup = AnswerMarkup("See [the status page](https://status.example.com) for updates.")
        #expect(markup.blocks[0].spans == [AnswerSpan("See the status page for updates.")])
    }

    @Test func headingsBecomeBoldParagraphs() {
        let markup = AnswerMarkup("## Next steps")
        #expect(markup.blocks == [AnswerBlock(id: 0, kind: .paragraph, spans: [AnswerSpan("Next steps", .bold)])])
    }

    @Test func unclosedMarksStyleTheRestOfTheLineWhileStreaming() {
        var markup = AnswerMarkup()
        markup.update("Sure. [check the acc")
        #expect(markup.blocks[0].spans == [AnswerSpan("Sure. "), AnswerSpan("check the acc", .note)])
        markup.update("[Don't promise")
        #expect(markup.blocks == [AnswerBlock(id: 0, kind: .note, spans: [AnswerSpan("Don't promise", .note)])])
        markup.update("- **Tod")
        #expect(markup.blocks[0].spans == [AnswerSpan("Tod", .bold)])
    }

    @Test func streamingGivesTheSameBlocksAsParsingAtOnce() {
        let answer = """
            Most of the delay came from the open's order burst.
            - **Today:** I'll send the affected accounts.
            - **Tomorrow:** we'll watch the open live.

            [Don't promise compensation. Check with Dealing first.]
            """
        var streamed = AnswerMarkup()
        var text = ""
        for character in answer {
            text.append(character)
            streamed.update(text)
        }
        #expect(streamed.blocks == AnswerMarkup(answer).blocks)
        #expect(streamed.blocks.map(\.id) == [0, 1, 2, 3])
    }

    @Test func blocksAlreadyShownKeepTheirIdentityAsTextArrives() {
        var markup = AnswerMarkup("First line.\nSecond")
        let first = markup.blocks[0]
        markup.update("First line.\nSecond line.\nThird")
        #expect(markup.blocks[0] == first)
        #expect(markup.blocks.map(\.text) == ["First line.", "Second line.", "Third"])
    }

    @Test func replacedTextIsParsedAfresh() {
        var markup = AnswerMarkup("- One\n- Two")
        markup.update("Something else entirely")
        #expect(markup.blocks == [AnswerBlock(id: 0, kind: .paragraph, spans: [AnswerSpan("Something else entirely")])])
    }

    @Test func textToSayLeavesOutNotesAndMarks() {
        let markup = AnswerMarkup(
            "We saw the spike [check the incident notes] at the open.\n- **Today:** the list\n2. Then a call\n"
                + "[Don't name a cause yet.]")
        #expect(markup.textToSay == "We saw the spike at the open.\n- Today: the list\n2. Then a call")
    }

    @Test func emptyAndBlankTextHasNoBlocks() {
        #expect(AnswerMarkup("").blocks.isEmpty)
        #expect(AnswerMarkup("\n  \n").blocks.isEmpty)
    }
}
