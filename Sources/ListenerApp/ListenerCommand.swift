import ArgumentParser
import Foundation
import ListenerCore
import ListenerMac

struct ListenerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "listener",
        abstract: "Transcribes both sides of a call and suggests answers on a hotkey.",
        discussion: """
            With no subcommand, Listener runs as a menu bar app with a floating window.
            Settings: ~/Library/Application Support/Listener/settings.json (see settings.example.json).
            """,
        subcommands: [
            LiveCommand.self,
            ReplayCommand.self,
            SessionsCommand.self,
            SummarizeCommand.self,
            SecretsCommand.self,
            SpikeCommand.self,
        ]
    )

    @OptionGroup var options: GlobalOptions

    /// Runs the menu bar app. Settings that fail to load don't stop the app: it starts
    /// with defaults and shows the problem, and every Start reads the file again.
    @MainActor
    func launchApp() -> Never {
        let paths = ListenerPaths.current
        let loader = SettingsLoader(paths: paths)
        let explicitPath = options.settings
        let launchSettings: LoadedSettings
        do {
            launchSettings = try loader.load(explicitPath: explicitPath)
        } catch {
            let message = "Using default settings for now. \(ErrorText.describe(error))"
            Console.error(message)
            launchSettings = LoadedSettings(
                settings: Settings(), file: paths.settingsFile, fileExists: true, warnings: [message])
        }

        let settings = launchSettings.settings
        Task.detached(priority: .background) {
            _ = try? SessionFactory.deleteExpiredSessions(settings)
        }

        let secrets = StandardSecrets.chain(paths: paths)
        let environment = AppEnvironment(
            paths: paths,
            launchSettings: launchSettings,
            loadSettings: { try loader.load(explicitPath: explicitPath) },
            makeComponents: { try SessionFactory.live(settings: $0, secrets: secrets, callbacks: $1) },
            googleSetup: { SessionFactory.googleSetup($0) },
            prepareOnDeviceSpeech: { await SessionFactory.prepareOnDeviceSpeech($0, report: $1) },
            hasAnthropicKey: { secrets.secret(.anthropicAPIKey) != nil },
            sessionsDirectory: { SessionFactory.sessionsRoot($0) }
        )
        ListenerApplication.run(environment: environment)
    }
}

struct GlobalOptions: ParsableArguments {
    @Option(help: "Settings file to use instead of ~/Library/Application Support/Listener/settings.json.")
    var settings: String?

    /// Loads settings and prints any warnings, such as misspelt keys, to stderr.
    func loadSettings() throws -> LoadedSettings {
        let loaded = try SettingsLoader().load(explicitPath: settings)
        for warning in loaded.warnings {
            Console.error(warning)
        }
        return loaded
    }
}
