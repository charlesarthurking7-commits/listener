import Foundation
import ListenerCore

/// What the window needs from the rest of the app. The executable fills this in
/// from its component factory, so the UI never constructs providers itself.
public struct AppEnvironment: Sendable {
    public var paths: ListenerPaths
    /// The settings file in use: --settings, or settings.json in the support directory.
    public var settingsFile: URL
    /// The settings at launch. Hotkeys and window options come from these.
    public var launchSettings: LoadedSettings
    /// Read again at every Start, so edits to settings.json apply to the next call.
    public var loadSettings: @Sendable () throws -> LoadedSettings
    public var makeComponents: @Sendable (Settings, SessionCallbacks) throws -> SessionComponents
    /// The Google project and credentials a call would use, without connecting.
    public var googleSetup: @Sendable (Settings) -> GoogleSetup
    /// Checks the on-device speech model for the configured language and downloads it
    /// if needed, reporting progress. Returns when it is ready or has failed.
    public var prepareOnDeviceSpeech:
        @Sendable (Settings, @escaping @Sendable (OnDeviceSpeechStatus) -> Void) async -> Void
    public var hasAnthropicKey: @Sendable () -> Bool
    /// Where the Anthropic key is found, such as "Keychain" or a .env file, or nil.
    public var anthropicKeySource: @Sendable () -> String?
    /// Saves the key in the Keychain, or removes it there when nil.
    public var storeAnthropicKey: @Sendable (String?) throws -> Void
    /// A web page as a Markdown document for a call's background.
    public var importWebPage: @Sendable (URL, Settings) async throws -> String
    /// Writes the summaries earlier calls still owe, because the app quit or crashed
    /// while writing them, and returns their files.
    public var finishDueSummaries: @Sendable (Settings) async -> [URL]
    /// Claude for tidying dictation, or nil without an Anthropic key.
    public var makeLanguageModel: @Sendable () -> (any LanguageModelProvider)?
    /// The main window's section to open at launch ("calls", "call-types", "dictionary"
    /// or "settings"), or nil to start with only the floating window.
    public var mainWindowAtLaunch: String?
    /// "light" or "dark" to override the Mac's appearance, for trying both in a demo.
    public var appearance: String?

    public init(
        paths: ListenerPaths,
        settingsFile: URL,
        launchSettings: LoadedSettings,
        loadSettings: @escaping @Sendable () throws -> LoadedSettings,
        makeComponents: @escaping @Sendable (Settings, SessionCallbacks) throws -> SessionComponents,
        googleSetup: @escaping @Sendable (Settings) -> GoogleSetup,
        prepareOnDeviceSpeech:
            @escaping @Sendable (Settings, @escaping @Sendable (OnDeviceSpeechStatus) -> Void) async -> Void,
        hasAnthropicKey: @escaping @Sendable () -> Bool,
        anthropicKeySource: @escaping @Sendable () -> String?,
        storeAnthropicKey: @escaping @Sendable (String?) throws -> Void,
        importWebPage: @escaping @Sendable (URL, Settings) async throws -> String,
        finishDueSummaries: @escaping @Sendable (Settings) async -> [URL],
        makeLanguageModel: @escaping @Sendable () -> (any LanguageModelProvider)?,
        mainWindowAtLaunch: String? = nil,
        appearance: String? = nil
    ) {
        self.paths = paths
        self.settingsFile = settingsFile
        self.launchSettings = launchSettings
        self.loadSettings = loadSettings
        self.makeComponents = makeComponents
        self.googleSetup = googleSetup
        self.prepareOnDeviceSpeech = prepareOnDeviceSpeech
        self.hasAnthropicKey = hasAnthropicKey
        self.anthropicKeySource = anthropicKeySource
        self.storeAnthropicKey = storeAnthropicKey
        self.importWebPage = importWebPage
        self.finishDueSummaries = finishDueSummaries
        self.makeLanguageModel = makeLanguageModel
        self.mainWindowAtLaunch = mainWindowAtLaunch
        self.appearance = appearance
    }
}

/// Things the capture sources and speech providers report on their own while a call
/// runs. Called from their private queues.
public struct SessionCallbacks: Sendable {
    public var captureEvent: @Sendable (CaptureEvent) -> Void
    public var onDeviceSpeech: @Sendable (OnDeviceSpeechStatus) -> Void

    public init(
        captureEvent: @escaping @Sendable (CaptureEvent) -> Void,
        onDeviceSpeech: @escaping @Sendable (OnDeviceSpeechStatus) -> Void
    ) {
        self.captureEvent = captureEvent
        self.onDeviceSpeech = onDeviceSpeech
    }
}

public struct GoogleSetup: Sendable, Equatable {
    /// speech.googleProjectID, or else the quota project in the credentials file.
    public var projectID: String?
    /// Why the credentials could not be loaded, or nil if they were found.
    public var credentialsProblem: String?

    public init(projectID: String?, credentialsProblem: String?) {
        self.projectID = projectID
        self.credentialsProblem = credentialsProblem
    }
}
