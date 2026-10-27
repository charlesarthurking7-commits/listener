import Foundation

/// Settings as loaded, with the problems that did not stop loading.
public struct LoadedSettings: Sendable {
    public var settings: Settings
    /// Such as misspelt keys that were ignored.
    public var warnings: [String]

    public init(settings: Settings, warnings: [String] = []) {
        self.settings = settings
        self.warnings = warnings
    }

    /// The same settings with "auto" replaced by the provider it stands for on this Mac,
    /// so everything downstream (setup checks, pricing, session) sees a real provider:
    /// on-device recognition where the Mac supports it, because it is free and has no
    /// network round trip, and Google Cloud everywhere else.
    public func resolvingSpeechProvider(onDeviceAvailable: Bool) -> LoadedSettings {
        var resolved = self
        if settings.speech.provider == "auto" {
            resolved.settings.speech.provider = onDeviceAvailable ? "apple" : "google"
        }
        return resolved
    }
}

public struct SettingsError: Error, Equatable, CustomStringConvertible {
    /// The file the problems were found in.
    public var source: String
    public var problems: [String]

    public var description: String {
        if problems.count == 1 {
            return "\(source): \(problems[0])"
        }
        return "\(source):\n" + problems.map { "  - \($0)" }.joined(separator: "\n")
    }
}

/// Reads settings.json, fills everything it leaves out with defaults and checks the
/// result. Errors name the key that is wrong.
public struct SettingsLoader: Sendable {
    public var paths: ListenerPaths

    public init(paths: ListenerPaths = .current) {
        self.paths = paths
    }

    /// Loads `explicitPath`, or settings.json in the Application Support folder. A
    /// missing default file just means defaults; a missing explicit file is an error.
    public func load(explicitPath: String? = nil) throws -> LoadedSettings {
        let file = explicitPath.map { URL(fileURLWithPath: paths.expandingTilde($0)) } ?? paths.settingsFile
        let source = paths.abbreviating(file.path)
        guard FileManager.default.fileExists(atPath: file.path) else {
            if explicitPath != nil {
                throw SettingsError(source: source, problems: ["does not exist"])
            }
            return try settings(from: .object([:]), source: source)
        }
        return try settings(from: Self.read(file, source: source), source: source)
    }

    /// `document` over the defaults with `~` expanded, or the problems that make it unusable.
    func settings(from document: JSONValue, source: String) throws -> LoadedSettings {
        let (decoded, warnings) = try Self.decode(document, source: source)
        var settings = decoded
        settings.storage.directory = settings.storage.directory.map(paths.expandingTilde)
        settings.speech.googleCredentialsFile = settings.speech.googleCredentialsFile.map(paths.expandingTilde)

        let problems = Self.problems(in: settings)
        if !problems.isEmpty {
            throw SettingsError(source: source, problems: problems)
        }
        return LoadedSettings(settings: settings, warnings: warnings)
    }

    /// The JSON object in a settings file.
    static func read(_ file: URL, source: String) throws -> JSONValue {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw SettingsError(source: source, problems: ["could not be read (\(error.localizedDescription))"])
        }
        return try parse(data, source: source)
    }

    /// Decodes a settings file. Keys it leaves out keep their defaults at every level;
    /// keys it adds that no setting has are returned as warnings.
    public static func decode(_ data: Data, source: String = "settings.json") throws -> (Settings, [String]) {
        try decode(parse(data, source: source), source: source)
    }

    static func parse(_ data: Data, source: String) throws -> JSONValue {
        let document: JSONValue
        do {
            document = try JSONValue(parsing: data)
        } catch {
            throw SettingsError(source: source, problems: ["is not valid JSON (\(jsonErrorDetail(error)))"])
        }
        guard document.objectValue != nil else {
            throw SettingsError(source: source, problems: ["must hold a JSON object, { ... }, at the top level"])
        }
        return document
    }

    static func decode(_ document: JSONValue, source: String) throws -> (Settings, [String]) {
        let merged = try JSONValue(encoding: Settings()).merging(document)
        let settings: Settings
        do {
            settings = try JSONDecoder().decode(Settings.self, from: merged.data())
        } catch let error as DecodingError {
            throw SettingsError(source: source, problems: [describe(error, in: merged)])
        }

        let effective = try JSONValue(encoding: settings)
        let warnings = unknownKeys(in: document, known: effective, path: []).map { key in
            "Unknown setting \"\(key)\" was ignored. settings.example.json lists every option."
        }
        return (settings, warnings)
    }

    /// A starter settings.json with the values people change most, for "Open settings file".
    public static func starterFile() -> Data {
        let defaults = Settings()
        let starter: JSONValue = .object([
            "speech": .object([
                "provider": .string(defaults.speech.provider),
                "googleProjectID": .null,
                "languageCode": .string(defaults.speech.languageCode),
            ]),
            "answers": .object(["context": .string(defaults.answers.context)]),
            "hotkeys": .object([
                "quickAnswer": .string(defaults.hotkeys.quickAnswer),
                "deepAnswer": .string(defaults.hotkeys.deepAnswer),
                "recap": .string(defaults.hotkeys.recap),
                "toggleListening": .string(defaults.hotkeys.toggleListening),
                "toggleWindow": .string(defaults.hotkeys.toggleWindow),
            ]),
            "storage": .object([
                "retentionDays": .integer(defaults.storage.retentionDays),
                "saveAudio": .bool(defaults.storage.saveAudio),
            ]),
        ])
        return (try? fileData(starter)) ?? Data("{}".utf8)
    }

    /// JSON laid out the way Listener writes settings.json: indented, keys sorted, slashes left alone.
    static func fileData(_ document: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    /// Writes the starter file unless a settings file already exists. Returns its location.
    @discardableResult
    public func createSettingsFileIfMissing() throws -> URL {
        let file = paths.settingsFile
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
            try Self.starterFile().write(to: file, options: .atomic)
        }
        return file
    }

    /// Values that decode fine but make no sense.
    static func problems(in settings: Settings) -> [String] {
        var problems: [String] = []
        func require(_ condition: Bool, _ key: String, _ message: String) {
            if !condition {
                problems.append("\(key) \(message)")
            }
        }
        func requireOneOf(_ value: String, _ allowed: [String], _ key: String) {
            let list = allowed.map { "\"\($0)\"" }.joined(separator: ", ")
            require(allowed.contains(value), key, "is \"\(value)\", but must be one of \(list)")
        }

        requireOneOf(settings.speech.provider, ["auto", "google", "apple", "fake"], "speech.provider")
        requireOneOf(
            settings.speech.endpointingSensitivity, ["standard", "short", "supershort"],
            "speech.endpointingSensitivity")
        require(
            (30...290).contains(settings.speech.rotateAfterSeconds), "speech.rotateAfterSeconds",
            "must be between 30 and 290, because Google closes streams after 300 seconds")
        requireOneOf(settings.capture.systemAudioBackend, ["tap", "sck"], "capture.systemAudioBackend")
        require(settings.turns.silenceMs > 0, "turns.silenceMs", "must be more than 0")
        require(settings.turns.minSpeechMs >= 0, "turns.minSpeechMs", "must not be negative")
        require(settings.answers.quick.maxTokens > 0, "answers.quick.maxTokens", "must be more than 0")
        require(settings.answers.deep.maxTokens > 0, "answers.deep.maxTokens", "must be more than 0")
        require(settings.answers.recap.maxTokens > 0, "answers.recap.maxTokens", "must be more than 0")
        require(settings.summary.model.maxTokens > 0, "summary.model.maxTokens", "must be more than 0")
        requireOneOf(settings.dictation.microphone, ["built-in", "default"], "dictation.microphone")
        requireOneOf(settings.dictation.recognizer, ["parakeet", "apple"], "dictation.recognizer")
        require(settings.dictation.model.maxTokens > 0, "dictation.model.maxTokens", "must be more than 0")
        require(
            settings.answers.transcriptBudgetTokens > 0, "answers.transcriptBudgetTokens", "must be more than 0")
        require(
            settings.answers.transcriptBudgetTokens <= settings.answers.transcriptHardCapTokens,
            "answers.transcriptBudgetTokens", "must not be more than answers.transcriptHardCapTokens")
        require(settings.storage.retentionDays >= 0, "storage.retentionDays", "must be 0 (keep forever) or more")
        require(
            (0.2...1).contains(settings.window.opacity), "window.opacity", "must be between 0.2 and 1")
        problems += settings.hotkeys.problems.map(\.message)
        return problems
    }

    static func describe(_ error: DecodingError, in document: JSONValue) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            let found = document.value(at: context.codingPath.map(\.stringValue))?.preview ?? "something else"
            return "\(keyPath(context.codingPath)) should be \(expectation(for: type)), but is \(found)"
        case .valueNotFound(let type, let context):
            return "\(keyPath(context.codingPath)) must not be null, it should be \(expectation(for: type))"
        case .keyNotFound(let key, let context):
            if context.codingPath.isEmpty {
                return "is missing \"\(key.stringValue)\""
            }
            return "\(keyPath(context.codingPath)) is missing \"\(key.stringValue)\""
        case .dataCorrupted(let context):
            let found = document.value(at: context.codingPath.map(\.stringValue))?.preview ?? "this"
            return "\(keyPath(context.codingPath)) cannot be \(found)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func keyPath(_ codingPath: [any CodingKey]) -> String {
        codingPath.map(\.stringValue).joined(separator: ".")
    }

    private static func expectation(for type: Any.Type) -> String {
        if type == Int.self {
            return "a whole number"
        }
        if type == Double.self || type == Float.self {
            return "a number"
        }
        if type == String.self {
            return "text in double quotes"
        }
        if type == Bool.self {
            return "true or false"
        }
        if String(describing: type).hasPrefix("Array") {
            return "a list, [ ... ]"
        }
        return "an object, { ... }"
    }

    private static func unknownKeys(in document: JSONValue, known: JSONValue, path: [String]) -> [String] {
        guard let object = document.objectValue else {
            return []
        }
        let knownObject = known.objectValue ?? [:]
        var unknown: [String] = []
        for key in object.keys.sorted() {
            let value = object[key]!
            if let knownValue = knownObject[key] {
                unknown += unknownKeys(in: value, known: knownValue, path: path + [key])
            } else if value != .null {
                unknown.append((path + [key]).joined(separator: "."))
            }
        }
        return unknown
    }

    private static func jsonErrorDetail(_ error: any Error) -> String {
        var current: any Error = error
        if case DecodingError.dataCorrupted(let context) = error, let underlying = context.underlyingError {
            current = underlying
        }
        let nsError = current as NSError
        if let detail = nsError.userInfo[NSDebugDescriptionErrorKey] as? String {
            return detail
        }
        return String(describing: current)
    }
}
