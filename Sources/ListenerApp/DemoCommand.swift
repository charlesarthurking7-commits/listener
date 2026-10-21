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
        ListenerCommand.launchApp(options: options, demo: DemoCall(folder: folder, scriptedAnswers: scriptedAnswers))
    }
}

struct DemoCall: Sendable {
    var folder: URL
    var scriptedAnswers: Bool
}

/// Answers in the shape Claude gives them, for a demo without Claude.
enum DemoAnswers {
    @Sendable static func reply(to request: ModelRequest) -> String {
        let instruction = request.user.last?.text ?? ""
        if request.settings.maxTokens == 1 {
            return "OK"
        }
        if instruction.hasSuffix("Write the notes.") {
            return summary
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
        A broker is asking why copy trades reached their followers late after the US open.
        - Delays of up to 30 seconds started at half two.
        - The fix went in at 2:40 and delays are now under a second.
        **Open for you:**
        - Send the list of affected accounts this afternoon.
        """

    static let summary = """
        ## Summary
        - Copy trades reached followers late after the US open.

        ## Decisions
        None recorded.

        ## Action items
        - [ ] **Me**: send the affected accounts this afternoon

        ## Open questions
        None.

        ## Follow-up email
        Subject: Today's delayed executions
        """
}
