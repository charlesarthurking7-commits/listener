import Foundation
import Testing

@testable import ListenerCore

struct SettingsLoaderTests {
    @Test func emptyFileGivesDefaults() throws {
        let (settings, warnings) = try decode("{}")
        #expect(settings == Settings())
        #expect(warnings.isEmpty)
    }

    @Test func missingKeysKeepDefaultsAtEveryLevel() throws {
        let (settings, _) = try decode(
            #"{"answers": {"quick": {"model": "claude-haiku-6"}}, "turns": {"silenceMs": 500}}"#)
        var expected = Settings()
        expected.answers.quick.model = "claude-haiku-6"
        expected.turns.silenceMs = 500
        #expect(settings == expected)
    }

    @Test func pricesMergeIntoTheDefaultTable() throws {
        let (settings, _) = try decode(#"{"prices": {"models": {"claude-haiku-5-5": {"input": 0.2}}}}"#)
        let haiku = try #require(settings.prices.models["claude-haiku-5-5"])
        #expect(haiku.input == 0.2)
        #expect(haiku.output == 0.5)
        #expect(haiku.longPromptThreshold == 100_000)
        #expect(settings.prices.models["claude-sonnet-5-5"] == PriceTable.standard.models["claude-sonnet-5-5"])
    }

    @Test func nullClearsAnOptionalSetting() throws {
        let (settings, warnings) = try decode(#"{"speech": {"googleProjectID": null, "googleCredentialsFile": null}}"#)
        #expect(settings.speech.googleProjectID == nil)
        #expect(warnings.isEmpty)
    }

    @Test func wrongTypeNamesTheKeyAndTheValue() {
        expectProblem(
            #"{"storage": {"retentionDays": "thirty"}}"#,
            "storage.retentionDays should be a whole number, but is \"thirty\"")
        expectProblem(#"{"storage": {"saveAudio": 1}}"#, "storage.saveAudio should be true or false, but is 1")
        expectProblem(#"{"speech": {"model": 3}}"#, "speech.model should be text in double quotes, but is 3")
        expectProblem(#"{"speech": "google"}"#, "speech should be an object, { ... }, but is \"google\"")
    }

    @Test func nullForARequiredValueIsAnError() {
        expectProblem(#"{"window": {"opacity": null}}"#, "window.opacity must not be null, it should be a number")
    }

    @Test func invalidEnumValueNamesTheKey() {
        expectProblem(#"{"answers": {"deep": {"thinking": "always"}}}"#, "answers.deep.thinking cannot be \"always\"")
    }

    @Test func newPriceEntryMustBeComplete() {
        expectProblem(
            #"{"prices": {"models": {"my-model": {"input": 1}}}}"#, "prices.models.my-model is missing \"output\"")
    }

    @Test func brokenJSONIsReportedAsSuch() throws {
        let error = try #require(throws: SettingsError.self) { try decode(#"{"speech": {"model": }"#) }
        #expect(error.problems.count == 1)
        #expect(error.problems[0].hasPrefix("is not valid JSON ("))
        #expect(error.description.hasPrefix("settings.json: is not valid JSON"))
    }

    @Test func topLevelMustBeAnObject() {
        expectProblem("[1, 2]", "must hold a JSON object, { ... }, at the top level")
    }

    @Test func unknownKeysAreIgnoredWithAWarning() throws {
        let (settings, warnings) = try decode(
            #"{"colour": "red", "storage": {"retentionDay": 5, "saveAudio": true}, "speech": {"googleProjectID": "p"}}"#
        )
        #expect(settings.storage.saveAudio)
        #expect(settings.storage.retentionDays == 30)
        #expect(settings.speech.googleProjectID == "p")
        #expect(
            warnings == [
                "Unknown setting \"colour\" was ignored. settings.example.json lists every option.",
                "Unknown setting \"storage.retentionDay\" was ignored. settings.example.json lists every option.",
            ])
    }

    @Test func missingDefaultFileGivesDefaults() throws {
        let home = try makeHome()
        let loaded = try SettingsLoader(paths: ListenerPaths(home: home), environment: [:]).load()
        #expect(loaded.settings == Settings())
        #expect(!loaded.fileExists)
        #expect(loaded.file == home.appendingPathComponent("Library/Application Support/Listener/settings.json"))
    }

    @Test func missingExplicitFileIsAnError() throws {
        let home = try makeHome()
        let loader = SettingsLoader(paths: ListenerPaths(home: home), environment: [:])
        let error = try #require(throws: SettingsError.self) { try loader.load(explicitPath: "~/nope.json") }
        #expect(error.description == "~/nope.json: does not exist")
    }

    @Test func loadsTheFileAndExpandsTildes() throws {
        let home = try makeHome()
        let paths = ListenerPaths(home: home)
        try FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        try Data(#"{"storage": {"directory": "~/Calls"}, "speech": {"googleCredentialsFile": "~/key.json"}}"#.utf8)
            .write(to: paths.settingsFile)

        let loaded = try SettingsLoader(paths: paths, environment: [:]).load()
        #expect(loaded.fileExists)
        #expect(loaded.settings.storage.directory == home.appendingPathComponent("Calls").path)
        #expect(loaded.settings.speech.googleCredentialsFile == home.appendingPathComponent("key.json").path)
    }

    @Test func environmentOverridesTheFile() throws {
        let environment = [
            "LISTENER_GOOGLE_PROJECT": "pelican-ops",
            "LISTENER_SPEECH_PROVIDER": "fake",
            "LISTENER_LANGUAGE": "en-US",
            "LISTENER_QUICK_MODEL": "claude-haiku-6",
            "LISTENER_RETENTION_DAYS": " 7 ",
            "LISTENER_SAVE_AUDIO": "Yes",
            "LISTENER_STORAGE_DIR": "~/Calls",
            "LISTENER_SPEECH_MODEL": "",
        ]
        let home = try makeHome()
        let settings = try SettingsLoader(paths: ListenerPaths(home: home), environment: environment).load().settings
        #expect(settings.speech.googleProjectID == "pelican-ops")
        #expect(settings.speech.provider == "fake")
        #expect(settings.speech.languageCode == "en-US")
        #expect(settings.speech.model == "chirp_3")
        #expect(settings.answers.quick.model == "claude-haiku-6")
        #expect(settings.storage.retentionDays == 7)
        #expect(settings.storage.saveAudio)
        #expect(settings.storage.directory == home.appendingPathComponent("Calls").path)
    }

    @Test func badEnvironmentValuesNameTheVariable() throws {
        let environment = ["LISTENER_RETENTION_DAYS": "a week", "LISTENER_SAVE_AUDIO": "maybe"]
        let loader = SettingsLoader(paths: ListenerPaths(home: try makeHome()), environment: environment)
        let error = try #require(throws: SettingsError.self) { try loader.load() }
        #expect(error.source == "Environment")
        #expect(
            error.problems == [
                "LISTENER_RETENTION_DAYS should be a whole number, but is \"a week\"",
                "LISTENER_SAVE_AUDIO should be true or false, but is \"maybe\"",
            ])
    }

    @Test func validationNamesTheKeyAndTheVariableThatSetIt() throws {
        let loader = SettingsLoader(
            paths: ListenerPaths(home: try makeHome()), environment: ["LISTENER_SPEECH_PROVIDER": "deepgram"])
        let error = try #require(throws: SettingsError.self) { try loader.load() }
        #expect(
            error.problems == [
                "speech.provider is \"deepgram\", but must be one of \"google\", \"fake\" (set by LISTENER_SPEECH_PROVIDER)"
            ])
    }

    @Test func validationReportsEveryProblem() {
        var settings = Settings()
        settings.capture.systemAudioBackend = "blackhole"
        settings.window.opacity = 0
        settings.storage.retentionDays = -1
        settings.answers.transcriptBudgetTokens = 100_000
        settings.hotkeys.deepAnswer = "option+d"
        settings.hotkeys.toggleListening = "ctrl+option+space"
        let messages = SettingsLoader.problems(in: settings).map(\.message)
        #expect(
            messages == [
                "capture.systemAudioBackend is \"blackhole\", but must be one of \"tap\", \"sck\"",
                "answers.transcriptBudgetTokens must not be more than answers.transcriptHardCapTokens",
                "storage.retentionDays must be 0 (keep forever) or more",
                "window.opacity must be between 0.2 and 1",
                "hotkeys.deepAnswer \"option+d\" uses only option or option+shift, which macOS 15 does not allow for global hotkeys; add ctrl or cmd",
                "hotkeys.toggleListening \"ctrl+option+space\" is the same as hotkeys.quickAnswer",
            ])
        #expect(SettingsLoader.problems(in: Settings()).isEmpty)
    }

    @Test func starterFileDecodesToDefaults() throws {
        let (settings, warnings) = try SettingsLoader.decode(SettingsLoader.starterFile())
        #expect(settings == Settings())
        #expect(warnings.isEmpty)
        let text = String(decoding: SettingsLoader.starterFile(), as: UTF8.self)
        #expect(text.contains("\"googleProjectID\" : null"))
    }

    @Test func starterFileNeverReplacesAnExistingFile() throws {
        let paths = ListenerPaths(home: try makeHome())
        let loader = SettingsLoader(paths: paths, environment: [:])
        let file = try loader.createSettingsFileIfMissing()
        #expect(try Data(contentsOf: file) == SettingsLoader.starterFile())

        try Data(#"{"turns": {"silenceMs": 900}}"#.utf8).write(to: file)
        try loader.createSettingsFileIfMissing()
        #expect(try loader.load().settings.turns.silenceMs == 900)
    }

    @Test func everyEnvironmentOverrideNamesARealSetting() throws {
        let effective = try JSONValue(encoding: Settings())
        for override in SettingsLoader.environmentOverrides {
            let path = override.setting.split(separator: ".").map(String.init)
            let parent = effective.value(at: Array(path.dropLast()))
            #expect(parent?.objectValue != nil, "\(override.variable)")
            #expect(override.variable.hasPrefix("LISTENER_"))
        }
    }

    @Test func exampleSettingsFileDecodesWithoutWarnings() throws {
        let (settings, warnings) = try SettingsLoader.decode(Data(contentsOf: exampleFile))
        #expect(warnings.isEmpty)
        #expect(SettingsLoader.problems(in: settings).isEmpty)
        #expect(!settings.answers.context.isEmpty)
    }

    @Test func exampleSettingsFileShowsEveryOption() throws {
        let example = try JSONValue(parsing: Data(contentsOf: exampleFile))
        let defaults = try JSONValue(encoding: Settings())
        for path in keyPaths(defaults) {
            #expect(example.value(at: path) != nil, "settings.example.json lacks \(path.joined(separator: "."))")
        }
    }

    private var exampleFile: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("settings.example.json")
    }

    private func keyPaths(_ value: JSONValue, prefix: [String] = []) -> [[String]] {
        guard let object = value.objectValue else {
            return [prefix]
        }
        return object.flatMap { key, child in keyPaths(child, prefix: prefix + [key]) }
    }

    private func decode(_ json: String) throws -> (Settings, [String]) {
        try SettingsLoader.decode(Data(json.utf8))
    }

    private func expectProblem(_ json: String, _ problem: String, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try decode(json)
            Issue.record("Expected an error for \(json)", sourceLocation: sourceLocation)
        } catch let error as SettingsError {
            #expect(error.problems == [problem], sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }
}

func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("listener-home-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}
