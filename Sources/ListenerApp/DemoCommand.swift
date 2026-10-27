import ArgumentParser
import Foundation
import ListenerCore

struct DemoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "demo",
        abstract: "Open the app with a recorded call in place of your microphone and system audio.",
        discussion: """
            Press Start and the call plays into the window as if it were live: transcript,
            answers, recap and summary. Nothing on this Mac is captured. Answers come from
            Claude, or with --scripted-answers from canned text that needs no API key.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Option(help: "A folder with me.wav, them.wav and script.json, like those in Fixtures.")
    var call = "Fixtures/delayed-executions"

    @Flag(help: "Canned answers instead of Claude: no API key, Keychain or network.")
    var scriptedAnswers = false

    @Option(help: "Open the main window at launch: calls, call-types, dictionary or settings.")
    var open: String?

    @Option(help: "Show the app in light or dark mode, whatever the Mac uses.")
    var appearance: String?

    func validate() throws {
        let folder = URL(fileURLWithPath: ListenerPaths.current.expandingTilde(call))
        for file in ["me.wav", "them.wav", "script.json"]
        where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path) {
            throw ValidationError("\(call) has no \(file).")
        }
    }

    @MainActor
    func launchApp() -> Never {
        let folder = URL(fileURLWithPath: ListenerPaths.current.expandingTilde(call)).standardizedFileURL
        ListenerCommand.launchApp(
            options: options, demo: DemoCall(folder: folder, scriptedAnswers: scriptedAnswers), open: open,
            appearance: appearance)
    }
}

struct DemoCall: Sendable {
    var folder: URL
    var scriptedAnswers: Bool
}

/// Answers in the shape Claude gives them, for a demo without Claude.
enum DemoAnswers {
    static var model: ScriptedLanguageModel { ScriptedLanguageModel(reply: reply) }

    @Sendable static func reply(to request: ModelRequest) -> String {
        let instruction = request.user.last?.text ?? ""
        if request.settings.maxTokens == 1 {
            return "OK"
        }
        if instruction.hasSuffix("Write the notes.") {
            return summary(request: instruction)
        }
        if instruction.hasSuffix("Recap the call so far.") {
            return recap
        }
        return request.settings == AnswerSettings().deep ? deep : quick
    }

    static let quick = """
        [Nothing asked of you: they're explaining why copy trades reached followers late after the open.]
        Thanks, that's clear. Which accounts were hit hardest?
        """

    static let deep = """
        We saw it too. Volume at the open was about six times normal, which backed up the follower order queue.
        - We scaled out the workers at 2:40, and delays have been under a second since.
        - Extra workers go on before tomorrow's open.
        [Check the incident reference before you quote it.]
        """

    static let recap = """
        A broker is asking why copy trades reached their followers late after the US open, and the call \
        has moved on to what happens before tomorrow's open.
        - Delays of up to 30 seconds started at half two, when volume was about six times normal.
        - The follower order queue backed up; nothing was lost, every trade was copied in the end.
        - Workers were scaled out at 2:40 and delays have been under a second since.
        - The broker's dealing desk had complaints from around 40 followers.
        - They want to know whether slippage on the late fills will be refunded.
        **Open for you:**
        - Send the list of affected accounts this afternoon.
        - Say whether the late fills qualify for a slippage refund.
        **Agreed:**
        - You will add workers before tomorrow's open.
        - The broker will forward the complaints with account numbers.
        """

    /// The notes for Fixtures/delayed-executions, dated with the request's date line as
    /// Claude would.
    static func summary(request: String) -> String {
        let firstLine = request.prefix { $0 != "\n" }
        let dateLine = firstLine.hasPrefix("Date line: ") ? firstLine.dropFirst("Date line: ".count) : ""
        return """
            # Kestrelmoor Markets: delayed copy trades after the US open
            *\(dateLine)*

            ## Summary
            - Hannah at Kestrelmoor Markets called about a flood of complaints since the US open.
            - From half two, copy trades reached their followers late, some by 30 seconds: volume at the open \
            hit six times normal and backed up the follower order queue.
            - The workers were scaled out at 2:40, and delays have been under a second since.
            - Kestrelmoor's compliance team want numbers on the affected accounts today.
            - The incident reference is INC-4471.

            ## Decisions
            - Extra workers go on before tomorrow's open, so it shouldn't happen again.

            ## Action items
            - [ ] **Me**: send Hannah the affected accounts, and by how much (due this afternoon)
            - [ ] **Me**: check with client services whether Pelican will cover the slippage on the late fills
            - [ ] **Me**: send the incident report for INC-4471 (due within five working days)

            ## Open questions
            - Will Pelican cover the slippage on the late fills?

            ## Follow-up email
            **Subject:** INC-4471: delayed copy trades after the US open

            Hi Hannah,

            Thanks for the call. From half two, volume at the US open hit six times normal and backed up our \
            follower order queue, so some copy trades reached your followers up to 30 seconds late. We scaled \
            out the workers at 2:40, delays have been under a second since, and we're adding extra workers \
            before tomorrow's open.

            I'll send the list of affected accounts this afternoon, and I'm checking with client services \
            whether we can cover the slippage on the late fills. You'll have the incident report within five \
            working days. The reference is INC-4471.

            Best regards,
            [name]
            """
    }
}
