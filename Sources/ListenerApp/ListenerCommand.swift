import ArgumentParser
import Foundation
import ListenerCore
import ListenerMac
import os

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
            ReadPageCommand.self,
            DemoCommand.self,
            SecretsCommand.self,
        ]
    )

    @OptionGroup var options: GlobalOptions

    @MainActor
    func launchApp() -> Never {
        Self.launchApp(options: options, demo: nil)
    }

    /// Runs the menu bar app. Settings that fail to load don't stop the app: it starts
    /// with defaults and shows the problem, and every Start reads the file again. A demo
    /// plays a recorded call where a call would capture this Mac's audio.
    @MainActor
    static func launchApp(options: GlobalOptions, demo: DemoCall?) -> Never {
        let paths = ListenerPaths.current
        let loader = SettingsLoader(paths: paths)
        let explicitPath = options.settings
        let launchSettings: LoadedSettings
        do {
            launchSettings = try loader.load(explicitPath: explicitPath).resolvingSpeechProvider(
                onDeviceAvailable: AppleSpeech.isSupported)
        } catch {
            let message = "Using default settings for now. \(ErrorText.describe(error))"
            Console.error(message)
            launchSettings = LoadedSettings(settings: Settings(), warnings: [message])
        }

        let settings = launchSettings.settings
        Task.detached(priority: .background) {
            do {
                let deleted = try SessionStore.deleteExpired(
                    in: SessionStore.root(for: settings.storage), retentionDays: settings.storage.retentionDays)
                if !deleted.isEmpty {
                    Log.session.info("Deleted \(deleted.count) calls older than the retention period")
                }
            } catch {
                Log.session.error("Could not delete old calls: \(ErrorText.describe(error), privacy: .public)")
            }
        }

        let secrets = StandardSecrets.chain(paths: paths)
        let makeComponents: @Sendable (Settings, SessionCallbacks) throws -> SessionComponents =
            if let demo {
                { try SessionFactory.demo(demo, settings: $0, secrets: secrets, callbacks: $1) }
            } else {
                { try SessionFactory.live(settings: $0, secrets: secrets, callbacks: $1) }
            }
        let environment = AppEnvironment(
            paths: paths,
            launchSettings: launchSettings,
            loadSettings: {
                try loader.load(explicitPath: explicitPath).resolvingSpeechProvider(
                    onDeviceAvailable: AppleSpeech.isSupported)
            },
            makeComponents: makeComponents,
            googleSetup: { SessionFactory.googleSetup($0) },
            prepareOnDeviceSpeech: { await SessionFactory.prepareOnDeviceSpeech($0, report: $1) },
            hasAnthropicKey: { demo?.scriptedAnswers == true || secrets.secret(.anthropicAPIKey) != nil },
            importWebPage: { try await SessionFactory.importWebPage($0, settings: $1, secrets: secrets) },
            finishDueSummaries: { demo == nil ? await SessionFactory.finishDueSummaries($0, secrets: secrets) : [] }
        )
        ListenerApplication.run(environment: environment)
    }
}

struct CallTypeOptions: ParsableArguments {
    @Option(
        name: .customLong("call-type"),
        help: """
            The kind of call, e.g. Meeting: its instructions and documents go to Claude with every answer. \
            A path to a folder laid out the same way works too.
            """)
    var callType: String?

    /// The call type's instructions and documents, or none without --call-type.
    func load() throws -> CallContext {
        guard var callType else {
            return .none
        }
        var library = CallTypeLibrary(paths: .current)
        if callType.contains("/") {
            let folder = URL(fileURLWithPath: ListenerPaths.current.expandingTilde(callType)).standardizedFileURL
            library = CallTypeLibrary(directory: folder.deletingLastPathComponent())
            callType = folder.lastPathComponent
        } else {
            try library.createIfMissing()
        }
        let names = library.names()
        guard names.contains(callType) else {
            throw ValidationError(
                "There is no call type \"\(callType)\". Choose one of: \(names.joined(separator: ", ")).")
        }
        let loaded = library.load(callType, readText: DocumentText.read)
        for file in loaded.files {
            if let problem = file.problem {
                Console.error("\(file.name): \(problem)")
            }
        }
        Console.write("Call type \(callType), with \(loaded.context.documents.count) documents.\n")
        return loaded.context
    }
}

struct GlobalOptions: ParsableArguments {
    @Option(help: "Settings file to use instead of ~/Library/Application Support/Listener/settings.json.")
    var settings: String?

    /// Loads settings and prints any warnings, such as misspelt keys, to stderr.
    func loadSettings() throws -> LoadedSettings {
        let loaded = try SettingsLoader().load(explicitPath: settings).resolvingSpeechProvider(
            onDeviceAvailable: AppleSpeech.isSupported)
        for warning in loaded.warnings {
            Console.error(warning)
        }
        return loaded
    }
}
