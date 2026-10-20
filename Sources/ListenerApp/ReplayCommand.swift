import ArgumentParser
import Foundation
import ListenerCore
import ListenerMac

struct ReplayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "replay",
        abstract: "Run two recordings through the full pipeline, as if they were a live call.",
        discussion: """
            The recordings play at real time (or --speed times faster) into the same
            speech-to-text, transcript, answer and saving code a live call uses. With
            --script the transcript comes from the script instead of Google, so no
            speech-to-text account is needed. --ask-at asks for answers at those points
            in the recording and prints a latency table at the end.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Recording of your side (\"Me\"), a 16-bit WAV file.")
    var me: String

    @Argument(help: "Recording of the other side (\"Them\"), a 16-bit WAV file.")
    var them: String

    @Option(help: "Conversation script (JSON) to use instead of Google speech-to-text.")
    var script: String?

    @Option(help: "Playback speed. 1 is real time.")
    var speed: Double = 1

    @Option(name: .customLong("ask-at"), help: "Ask for answers at these times in the recording, e.g. 12.5,30,1:05.")
    var askAt: String?

    @Option(help: "Answer tier for --ask-at: quick or deep.")
    var tier: TierOption = .quick

    func validate() throws {
        guard speed > 0, speed <= 20 else {
            throw ValidationError("--speed must be more than 0 and at most 20.")
        }
        do {
            _ = try askAt.map(AskSchedule.parse)
        } catch {
            throw ValidationError("--ask-at: \(error)")
        }
        for path in [me, them] + [script].compactMap(\.self) where !FileManager.default.fileExists(atPath: expand(path))
        {
            throw ValidationError("\(path) does not exist.")
        }
    }

    func run() async throws {
        var settings = try options.loadSettings().settings
        let conversation = try script.map { try ConversationScript.load(from: URL(fileURLWithPath: expand($0))) }
        if conversation != nil {
            settings.speech.provider = "fake"
        }
        let (notices, noticeContinuation) = AsyncStream.makeStream(of: TerminalInput.self)
        let replay = try SessionFactory.replay(
            settings: settings,
            secrets: StandardSecrets.chain(),
            callbacks: .terminal(noticeContinuation),
            me: URL(fileURLWithPath: expand(me)),
            them: URL(fileURLWithPath: expand(them)),
            script: conversation,
            speed: speed
        )
        let askTimes = try askAt.map(AskSchedule.parse) ?? []
        if replay.components.languageModel == nil && !askTimes.isEmpty {
            Console.error("No Anthropic API key, so --ask-at answers will fail. Run: listener secrets set anthropic")
        }

        let session = CallSession(settings: settings, components: replay.components)
        Console.write("Replaying at \(speed)x speed. Ctrl-C stops early and saves.\n\n")
        try await session.start()

        let inputs = [schedule(askTimes, from: .now), endOfAudio(replay.sources), notices]
        let answers = await TerminalSession(session: session, style: Console.style, acceptsTyping: false)
            .run(extraInputs: inputs)
        if !askTimes.isEmpty {
            Console.write("\n" + LatencyReport.render(answers))
        }
    }

    /// Asks at each time in the recording, scaled by the playback speed.
    private func schedule(_ times: [Double], from start: ContinuousClock.Instant) -> AsyncStream<TerminalInput> {
        let speed = speed
        let tier = tier.answerTier
        return AsyncStream { continuation in
            let task = Task {
                for time in times {
                    try await Task.sleep(until: start + .seconds(time / speed), clock: .continuous)
                    continuation.yield(.ask(tier))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func endOfAudio(_ sources: [ReplaySource]) -> AsyncStream<TerminalInput> {
        AsyncStream { continuation in
            let task = Task {
                for source in sources {
                    await source.waitUntilFinished()
                }
                continuation.yield(.audioEnded)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func expand(_ path: String) -> String {
        ListenerPaths.current.expandingTilde(path)
    }
}

enum TierOption: String, ExpressibleByArgument, CaseIterable {
    case quick
    case deep

    var answerTier: AnswerTier {
        switch self {
        case .quick: .quick
        case .deep: .deep
        }
    }
}
