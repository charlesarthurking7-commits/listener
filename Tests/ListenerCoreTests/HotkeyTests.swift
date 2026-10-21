import Testing

@testable import ListenerCore

struct HotkeyTests {
    @Test func parsesTheDefaults() throws {
        let quick = try Hotkey(parsing: "ctrl+option+space")
        #expect(quick.modifiers == [.control, .option])
        #expect(quick.key.name == "space")
        #expect(quick.key.keyCode == 0x31)
        #expect(quick.displayString == "⌃⌥Space")

        let deep = try Hotkey(parsing: "ctrl+option+shift+space")
        #expect(deep.modifiers == [.control, .option, .shift])
        #expect(deep.displayString == "⌃⌥⇧Space")

        let toggle = try Hotkey(parsing: "ctrl+option+l")
        #expect(toggle.key.keyCode == 0x25)
        #expect(toggle.displayString == "⌃⌥L")
    }

    @Test func caseSpacingAndAliasesDoNotMatter() throws {
        let hotkey = try Hotkey(parsing: " Shift + ALT + Control + Enter ")
        #expect(hotkey == (try Hotkey(parsing: "ctrl+option+shift+return")))
        #expect(hotkey.description == "ctrl+option+shift+return")
        #expect(try Hotkey(parsing: "⌘+⇧+k").description == "shift+cmd+k")
        #expect(try Hotkey(parsing: "cmd+shift+k").displayString == "⇧⌘K")
    }

    @Test func keyCodesMatchTheANSILayout() throws {
        let expected: [String: UInt16] = [
            "a": 0x00, "s": 0x01, "q": 0x0C, "z": 0x06, "m": 0x2E, "1": 0x12, "5": 0x17, "0": 0x1D,
            "return": 0x24, "tab": 0x30, "escape": 0x35, "minus": 0x1B, "slash": 0x2C, "grave": 0x32,
            "f1": 0x7A, "f2": 0x78, "f5": 0x60, "f12": 0x6F,
        ]
        for (name, code) in expected {
            #expect(try Hotkey(parsing: "ctrl+\(name)").key.keyCode == code, "\(name)")
        }
        #expect(Set(HotkeyKey.all.map(\.keyCode)).count == HotkeyKey.all.count)
    }

    @Test func punctuationCanBeWrittenAsTheCharacter() throws {
        #expect(try Hotkey(parsing: "ctrl+option+/").key.name == "slash")
        #expect(try Hotkey(parsing: "ctrl+option+-").displayString == "⌃⌥-")
    }

    @Test func functionKeysMayStandAlone() throws {
        let hotkey = try Hotkey(parsing: "f6")
        #expect(hotkey.modifiers.isEmpty)
        #expect(hotkey.key.menuKeyEquivalent == "\u{F709}")
        #expect(hotkey.displayString == "F6")
    }

    @Test func rejectsWhatCannotWork() {
        #expect(throws: HotkeyError.empty) { try Hotkey(parsing: " ") }
        #expect(throws: HotkeyError.unknownPart("ctl")) { try Hotkey(parsing: "ctl+space") }
        #expect(throws: HotkeyError.unknownPart("")) { try Hotkey(parsing: "ctrl++space") }
        #expect(throws: HotkeyError.missingKey) { try Hotkey(parsing: "ctrl+option") }
        #expect(throws: HotkeyError.moreThanOneKey("a", "b")) { try Hotkey(parsing: "ctrl+a+b") }
        #expect(throws: HotkeyError.needsModifier) { try Hotkey(parsing: "space") }
        #expect(throws: HotkeyError.needsModifier) { try Hotkey(parsing: "shift+a") }
        #expect(throws: HotkeyError.blockedByMacOS) { try Hotkey(parsing: "option+space") }
        #expect(throws: HotkeyError.blockedByMacOS) { try Hotkey(parsing: "option+shift+k") }
        #expect(throws: HotkeyError.unknownPart("f13")) { try Hotkey(parsing: "f13") }
    }

    @Test func settingsReportBadAndDuplicateHotkeys() {
        var settings = HotkeySettings()
        #expect(settings.problems.isEmpty)
        #expect(settings.hotkeys.count == 5)

        settings.quickAnswer = "ctrl+option+q"
        settings.deepAnswer = "option+control+Q"
        settings.toggleListening = "hyper+l"
        #expect(
            settings.problems == [
                HotkeyProblem(
                    action: .deepAnswer,
                    message: "hotkeys.deepAnswer \"option+control+Q\" is the same as hotkeys.quickAnswer"),
                HotkeyProblem(
                    action: .toggleListening,
                    message:
                        "hotkeys.toggleListening \"hyper+l\" \"hyper\" is not a modifier (ctrl, option, shift, cmd) or a key (a to z, 0 to 9, space, return, f1 to f12)"
                ),
            ])
        #expect(settings.hotkeys[.toggleListening] == nil)
    }
}
