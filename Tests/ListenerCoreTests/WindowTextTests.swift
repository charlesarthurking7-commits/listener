import Testing

@testable import ListenerCore

/// The small pieces of text the floating window and the menu show.
struct WindowTextTests {
    @Test func modelIDsReadAsNames() {
        #expect(DisplayFormat.modelName("claude-haiku-5-5") == "Haiku 5.5")
        #expect(DisplayFormat.modelName("claude-sonnet-5-5") == "Sonnet 5.5")
        #expect(DisplayFormat.modelName("claude-opus-4-1-20250805") == "Opus 4.1")
        #expect(DisplayFormat.modelName("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(DisplayFormat.modelName("claude-sonnet") == "Sonnet")
        #expect(DisplayFormat.modelName("gpt-test") == "gpt-test")
        #expect(DisplayFormat.modelName("claude-5") == "claude-5")
    }

    @Test func hotkeysSplitIntoKeycapsAndSpokenNames() throws {
        let deep = try Hotkey(parsing: "ctrl+option+shift+space")
        #expect(deep.keycaps == ["⌃", "⌥", "⇧", "Space"])
        #expect(deep.spokenName == "Control Option Shift Space")
        #expect(try Hotkey(parsing: "cmd+k").keycaps == ["⌘", "K"])
        #expect(try Hotkey(parsing: "f6").spokenName == "F6")
    }

    @Test func readinessProgressCountsWhatNeedsNothingMore() {
        let firstRun = Readiness.check(
            ReadinessInput(microphone: .granted, speechProvider: "google", hasAnthropicKey: false))
        #expect(Readiness.progress(firstRun) == ReadinessProgress(done: 2, total: 4))
        #expect(Readiness.needsAttention(firstRun))

        let ready = Readiness.check(
            ReadinessInput(
                microphone: .notDetermined, speechProvider: "google", googleProjectID: "listener-eu",
                hasAnthropicKey: true))
        #expect(Readiness.progress(ready).isComplete)
        #expect(!Readiness.needsAttention(ready))
        #expect(ready.map(\.summary) == ["macOS asks on Start", "macOS asks on Start", "Google Cloud", "Key found"])
    }

    @Test func onDeviceSpeechSummariesFollowTheDownload() {
        func summary(_ status: OnDeviceSpeechStatus) -> String {
            Readiness.check(
                ReadinessInput(
                    microphone: .granted, speechProvider: "apple", onDeviceSpeech: status, hasAnthropicKey: true)
            )[2].summary
        }
        #expect(summary(.checking) == "Checking")
        #expect(summary(.downloading(fractionCompleted: 0.42)) == "Downloading 42%")
        #expect(summary(.ready(locale: "en_GB")) == "On this Mac")
        #expect(summary(.failed("No model")) == "Unavailable")
    }

    @Test func outcomeDetailsSkipAnUnknownLength() {
        let outcome = CallOutcome(directory: "/s/call", summaryFile: nil, duration: nil, turnCount: 1, cost: 0.004)
        #expect(outcome.details == "1 turn · <$0.01")
    }
}
