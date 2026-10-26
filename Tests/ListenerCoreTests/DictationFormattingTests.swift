import Testing

@testable import ListenerCore

struct DictationFormattingTests {
    @Test func textWithoutAListStaysPlain() {
        #expect(DictationFormatting.html(for: "Hi Sam,\n\nThanks for that.\n\nCheers,\nCharlie") == nil)
        #expect(DictationFormatting.html(for: "We need 3. Not 4.") == nil)
        #expect(DictationFormatting.html(for: "-- \nCharlie") == nil)
    }

    @Test func bulletsBecomeAListAndTheLinesAroundItKeepTheirLayout() {
        let text =
            "Hi team,\n\nThe things we need are:\n- the new symbol list\n- the margin settings\n\nThanks,\nCharlie"
        #expect(
            DictationFormatting.html(for: text)
                == "<meta charset=\"utf-8\"><div>Hi team,</div><div><br></div><div>The things we need are:</div>"
                + "<ul><li>the new symbol list</li><li>the margin settings</li></ul><div><br></div>"
                + "<div>Thanks,</div><div>Charlie</div>")
    }

    @Test func stepsBecomeANumberedListThatKeepsItsFirstNumber() {
        #expect(
            DictationFormatting.html(for: "1. Restart the bridge.\n2. Check the FIX logs.")
                == "<meta charset=\"utf-8\"><ol><li>Restart the bridge.</li><li>Check the FIX logs.</li></ol>")
        #expect(DictationFormatting.html(for: "3) Confirm the fills.")?.contains("<ol start=\"3\">") == true)
    }

    @Test func aBulletListStraightAfterANumberedOneIsItsOwnList() {
        let html = DictationFormatting.html(for: "1. One\n2. Two\n- aside")
        #expect(html?.hasSuffix("<ol><li>One</li><li>Two</li></ol><ul><li>aside</li></ul>") == true)
    }

    @Test func linesAndListsBecomeBlocks() {
        #expect(
            DictationFormatting.blocks(for: "Steps:\n3. One\n4. Two\n\n- aside\nThanks")
                == [
                    .line("Steps:"), .list(numbered: true, start: 3, items: ["One", "Two"]), .blank,
                    .list(numbered: false, start: 1, items: ["aside"]), .line("Thanks"),
                ])
    }

    @Test func textIsEscaped() {
        let html = DictationFormatting.html(for: "- P&L <draft> \"v2\"")
        #expect(html?.contains("<li>P&amp;L &lt;draft&gt; &quot;v2&quot;</li>") == true)
    }

    @Test func otherBulletMarksAndIndentsCount() {
        #expect(DictationFormatting.html(for: "• one\n  * two")?.contains("<ul><li>one</li><li>two</li></ul>") == true)
    }
}
