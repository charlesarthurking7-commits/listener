import ArgumentParser
import Foundation
import ListenerCore
import ListenerMac

struct LiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "live",
        abstract: "Listen to a call with the transcript in this terminal.",
        discussion: """
            Captures your microphone as "Me" and system audio as "Them" and prints the
            transcript as it settles, with what is being said right now on a line that
            updates in place. Press Enter for a quick answer, d and Enter for a deep one,
            r and Enter for a recap. Ctrl-C stops, saves the call and writes the summary.
            """
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var callType: CallTypeOptions

    @Flag(help: "Show the transcript in this terminal. (For the window, run listener without arguments.)")
    var terminal = false

    func validate() throws {
        if !terminal {
            throw ValidationError("listener live needs --terminal. For the window, run listener without arguments.")
        }
    }

    func run() async throws {
        let settings = try options.loadSettings().settings
        let (notices, noticeContinuation) = AsyncStream.makeStream(of: TerminalInput.self)
        let components = try SessionFactory.live(
            settings: settings, secrets: StandardSecrets.chain(), callbacks: .terminal(noticeContinuation))
        if components.languageModel == nil {
            Console.error(
                "No Anthropic API key, so answers and the summary are off. Run: listener secrets set anthropic")
        }

        let session = CallSession(settings: settings, components: components, call: try callType.load())
        Console.write("Starting. The first time, macOS asks for microphone and system audio access.\n")
        try await session.start()
        Console.write(TerminalSession.keyHint)
        _ = await TerminalSession(session: session, style: Console.style, acceptsTyping: true)
            .run(extraInputs: [notices])
    }
}
