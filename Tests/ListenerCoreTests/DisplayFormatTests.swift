import Foundation
import Testing

@testable import ListenerCore

struct DisplayFormatTests {
    @Test func clock() {
        #expect(DisplayFormat.clock(0) == "0:00")
        #expect(DisplayFormat.clock(7.9) == "0:07")
        #expect(DisplayFormat.clock(725) == "12:05")
        #expect(DisplayFormat.clock(3723) == "1:02:03")
        #expect(DisplayFormat.clock(-5) == "0:00")
        #expect(DisplayFormat.clock(.nan) == "0:00")
    }

    @Test func tokenCounts() {
        #expect(DisplayFormat.tokens(0) == "0")
        #expect(DisplayFormat.tokens(850) == "850")
        #expect(DisplayFormat.tokens(1_000) == "1k")
        #expect(DisplayFormat.tokens(1_249) == "1.2k")
        #expect(DisplayFormat.tokens(9_960) == "10k")
        #expect(DisplayFormat.tokens(20_000) == "20k")
    }

    @Test func runningCost() {
        #expect(DisplayFormat.cost(0) == "$0.00")
        #expect(DisplayFormat.cost(0.004) == "<$0.01")
        #expect(DisplayFormat.cost(1.916) == "$1.92")
        #expect(DisplayFormat.cost(12.4) == "$12.40")
    }

    @Test func preciseCost() {
        #expect(DisplayFormat.preciseCost(0.00063) == "$0.0006")
        #expect(DisplayFormat.preciseCost(0.0412) == "$0.0412")
        #expect(DisplayFormat.preciseCost(1.5) == "$1.50")
    }

    @Test func latency() {
        #expect(DisplayFormat.latency(milliseconds: nil) == "-")
        #expect(DisplayFormat.latency(milliseconds: 639.6) == "640 ms")
        #expect(DisplayFormat.latency(milliseconds: -120) == "-120 ms")
        #expect(DisplayFormat.latency(milliseconds: 1240) == "1.24 s")
        #expect(DisplayFormat.latency(milliseconds: 12_340) == "12.3 s")
    }

    @Test func errorText() {
        struct Described: Error, CustomStringConvertible {
            var description: String { "described" }
        }
        struct Localized: LocalizedError {
            var errorDescription: String? { "localized" }
        }
        enum Plain: Error {
            case broken
        }
        #expect(ErrorText.describe(Described()) == "described")
        #expect(ErrorText.describe(Localized()) == "localized")
        #expect(ErrorText.describe(SettingsError(source: "x.json", problems: ["bad"])) == "x.json: bad")
        #expect(!ErrorText.describe(Plain.broken).isEmpty)
        let nsError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "readable"])
        #expect(ErrorText.describe(nsError) == "readable")
    }
}

struct ReadinessTests {
    private let ready = ReadinessInput(
        microphone: .granted, speechProvider: "google", googleProjectID: "pelican-ops", googleCredentialsProblem: nil,
        hasAnthropicKey: true)

    @Test func everythingInPlace() {
        let items = Readiness.check(ready)
        #expect(items.map(\.id) == ["microphone", "systemAudio", "speech", "answers"])
        #expect(items.map(\.status) == [.ready, .willAsk, .ready, .ready])
        #expect(!Readiness.blocksStart(items))
    }

    @Test func deniedMicrophoneBlocksAndLinksToSettings() {
        var input = ready
        input.microphone = .denied
        let item = Readiness.check(input)[0]
        #expect(item.status == .blocking)
        #expect(item.fix == .openPrivacySettings(.microphone))
        #expect(
            PrivacyPane.microphone.url == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #expect(Readiness.blocksStart(Readiness.check(input)))
    }

    @Test func undecidedMicrophoneIsAskedOnStart() {
        var input = ready
        input.microphone = .notDetermined
        #expect(Readiness.check(input)[0].status == .willAsk)
        #expect(!Readiness.blocksStart(Readiness.check(input)))
    }

    @Test func screenCaptureBackendReportsScreenRecording() {
        var input = ready
        input.screenRecording = .granted
        #expect(Readiness.check(input)[1].status == .ready)
        input.screenRecording = .denied
        #expect(Readiness.check(input)[1].fix == .openPrivacySettings(.screenAndSystemAudioRecording))
    }

    @Test func systemAudioIsAllowedOnceTheTapHasHeardSpeech() {
        var input = ready
        input.systemAudioHeard = true
        let item = Readiness.check(input)[1]
        #expect(item.status == .ready && item.summary == "Allowed" && item.fix == nil)
    }

    @Test func speechNeedsAProjectAndCredentials() {
        var input = ready
        input.googleProjectID = " "
        #expect(Readiness.check(input)[2].status == .blocking)
        #expect(Readiness.check(input)[2].fix == .editSettings)

        input.googleProjectID = "pelican-ops"
        input.googleCredentialsProblem = "no application default credentials"
        #expect(Readiness.check(input)[2].detail == "Google credentials: no application default credentials")
        #expect(Readiness.check(input)[2].fix == .runInTerminal("gcloud auth application-default login"))

        input.speechProvider = "fake"
        #expect(Readiness.check(input)[2].status == .blocking)
    }

    @Test func credentialsAreCheckedBeforeTheProject() {
        var input = ready
        input.googleProjectID = nil
        input.googleCredentialsProblem = "No Google credentials"
        #expect(Readiness.check(input)[2].fix == .runInTerminal("gcloud auth application-default login"))
    }

    @Test func onDeviceSpeechReportsTheModel() {
        var input = ready
        input.speechProvider = "apple"
        input.googleCredentialsProblem = "not used for on-device speech"
        #expect(Readiness.check(input)[2].status == .preparing)

        input.onDeviceSpeech = .downloading(fractionCompleted: 0.416)
        let downloading = Readiness.check(input)[2]
        #expect(downloading.status == .preparing)
        #expect(downloading.detail.contains("(42%)"))
        #expect(!Readiness.blocksStart(Readiness.check(input)))

        input.onDeviceSpeech = .ready(locale: "en-GB")
        #expect(Readiness.check(input)[2].status == .ready)

        input.onDeviceSpeech = .failed("On-device speech recognition needs macOS 26 or later.")
        let failed = Readiness.check(input)[2]
        #expect(failed.status == .blocking)
        #expect(failed.detail == "On-device speech recognition needs macOS 26 or later.")
        #expect(failed.fix == .editSettings)
    }

    @Test func missingAnthropicKeyOnlyLimits() {
        var input = ready
        input.hasAnthropicKey = false
        let items = Readiness.check(input)
        #expect(items[3].status == .limited)
        #expect(items[3].fix == .runInTerminal("listener secrets set anthropic"))
        #expect(!Readiness.blocksStart(items))
    }
}

struct LatencyReportTests {
    @Test func tableAndMedians() {
        var first = AnswerRecord(id: 1, tier: .quick, model: "haiku", askedAt: 12, cost: 0.0004)
        first.latency.hotkeyToFirstToken = 600
        first.latency.endOfSpeechToFirstToken = 1300
        first.latency.hotkeyToDone = 1800
        var second = AnswerRecord(id: 2, tier: .deep, model: "sonnet", askedAt: 75, cost: 0.0123)
        second.latency.hotkeyToFirstToken = 900
        second.latency.endOfSpeechToFirstToken = 1700
        let failed = AnswerRecord(id: 3, tier: .quick, model: "haiku", askedAt: 90, error: "overloaded")

        let expected = """
            #  Tier   Asked  Speech end > 1st token  Hotkey > 1st token  Hotkey > done     Cost
            1  quick   0:12                  1.30 s              600 ms         1.80 s  $0.0004
            2  deep    1:15                  1.70 s              900 ms              -  $0.0123
            3  quick   1:30                       -                   -              -  $0.0000
            Answer 3 failed: overloaded

            Hotkey to first token: median 750 ms, worst 900 ms (2 answers)
            Speech end to first token: median 1.50 s, worst 1.70 s (2 answers)
            1 of 2 within the 1.50 s target

            """
        #expect(LatencyReport.render([first, second, failed]) == expected)
    }

    @Test func noAnswers() {
        #expect(LatencyReport.render([]) == "No answers were requested.\n")
    }

    @Test func textTableKeepsNumbersAligned() {
        let table = TextTable.render(headers: ["#", "Name"], rows: [["9", "a"], ["10", "bb"]], leftAligned: [1])
        #expect(table == " #  Name\n 9  a\n10  bb\n")
    }

    @Test func askSchedule() throws {
        #expect(try AskSchedule.parse("30, 12.5,1:05") == [12.5, 30, 65])
        #expect(throws: AskSchedule.ParseError(text: "soon")) { try AskSchedule.parse("10,soon") }
        #expect(throws: AskSchedule.ParseError(text: "1:75")) { try AskSchedule.parse("1:75") }
        #expect(throws: AskSchedule.ParseError(text: "-3")) { try AskSchedule.parse("-3") }
        #expect(throws: AskSchedule.ParseError(text: "inf")) { try AskSchedule.parse("inf") }
    }
}
