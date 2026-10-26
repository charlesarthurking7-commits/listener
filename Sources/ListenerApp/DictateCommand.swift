import ArgumentParser
import Foundation
import ListenerCore
import ListenerMac

struct DictateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dictate",
        abstract: "Dictate the way fn fn does in the app, and print what it would type.",
        discussion: """
            With no file or text, records from the microphone until you press Return. Nothing is pasted \
            anywhere: this is for checking what dictation hears and how it tidies it.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Option(help: "A 16 kHz WAV file to dictate from instead of the microphone.")
    var file: String?

    @Option(help: "Tidy this text as if it had been heard, without speech recognition.")
    var text: String?

    @Option(help: "The app the text is going into, e.g. \"Microsoft Outlook\".")
    var app: String?

    @Option(help: "The title of the window it is going into.")
    var window: String?

    func validate() throws {
        if file != nil && text != nil {
            throw ValidationError("Give --file or --text, not both.")
        }
    }

    func run() async throws {
        let settings = try options.loadSettings().settings
        let heard: String
        if let text {
            heard = text
        } else {
            heard = try await record(settings)
        }
        Console.write("Heard:\n\(heard)\n\n")

        let tidier = DictationTidier(
            model: SessionFactory.languageModel(StandardSecrets.chain()), settings: settings.dictation,
            aboutMe: settings.answers.context)
        let started = ContinuousClock.now
        let result = await tidier.tidy(heard, for: DictationTarget(appName: app, windowTitle: window))
        let elapsed = (ContinuousClock.now - started).inSeconds * 1000
        Console.write("Typed:\n\(result.text)\n\n")
        if let problem = result.problem {
            Console.error("Typed what was heard: \(problem)")
        }
        var details = ["tidied in \(DisplayFormat.latency(milliseconds: elapsed))"]
        if let usage = result.usage, let price = settings.prices.models[settings.dictation.model.model] {
            details.append("\(usage.promptTokens) tokens in, \(usage.outputTokens) out")
            details.append(DisplayFormat.preciseCost(price.cost(of: usage)))
        }
        Console.error(details.joined(separator: ", "))
    }

    private func record(_ settings: Settings) async throws -> String {
        let source: any AudioCaptureSource
        var length: Duration?
        if let file {
            let replay = try ReplaySource(
                url: URL(fileURLWithPath: ListenerPaths.current.expandingTilde(file)), speaker: .me, speed: 1)
            source = replay
            length = .seconds(Double(replay.audio.frameCount) / Double(replay.audio.sampleRate))
        } else {
            source = LiveAudioSources.dictationMicrophone(settings: settings.dictation)
        }
        let speech = try AppleSpeech.makeProvider(settings: settings) { state in
            if case .downloading(let fraction) = state {
                Console.error("Downloading the speech model: \(Int(fraction * 100))%")
            }
        }
        let recorder = DictationRecorder(source: source, speech: speech)
        let info = try await recorder.start { _ in }
        if let length {
            Console.error("Dictating \(info.device)…")
            try await Task.sleep(for: length)
        } else {
            Console.error("Listening on \(info.device). Press Return to stop.")
            for await _ in Console.typedLines() {
                break
            }
        }
        let stopped = ContinuousClock.now
        let heard = await recorder.finish()
        let settled = (ContinuousClock.now - stopped).inSeconds * 1000
        Console.error("Speech settled \(DisplayFormat.latency(milliseconds: settled)) after stopping")
        if let problem = heard.problem {
            Console.error("Speech recognition stopped early: \(problem)")
        }
        return heard.text
    }
}
