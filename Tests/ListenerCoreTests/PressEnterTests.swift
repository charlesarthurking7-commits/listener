import Testing

@testable import ListenerCore

struct PressEnterTests {
    @Test func pressEnterAtTheEndIsTakenOffAndPressed() {
        #expect(PressEnter.split("Yeah, that looks great. Press enter.") == ("Yeah, that looks great.", true))
        #expect(PressEnter.split("looks great press enter") == ("looks great", true))
        #expect(PressEnter.split("Are we good? press Enter!") == ("Are we good?", true))
    }

    @Test func pressReturnCountsToo() {
        #expect(PressEnter.split("Thanks, Sam, press return.") == ("Thanks, Sam", true))
    }

    @Test func pressEnterOnItsOwnPressesReturnWithNothingToType() {
        #expect(PressEnter.split("Press enter.") == ("", true))
    }

    @Test func pressEnterAnywhereElseIsJustWords() {
        let instructions = "Type your name and press enter to log in."
        #expect(PressEnter.split(instructions) == (instructions, false))
        #expect(PressEnter.split("We need to impress enter") == ("We need to impress enter", false))
        #expect(PressEnter.split("Hello team") == ("Hello team", false))
    }
}
