import Foundation
import ListenerCore

/// What the window needs from the rest of the app. The executable fills this in
/// from its component factory, so the UI never constructs providers itself.
public struct AppEnvironment: Sendable {
    public var paths: ListenerPaths
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
    public var sessionsDirectory: @Sendable (Settings) -> URL
    /// A web page as a Markdown document for a call's background.
    public var importWebPage: @Sendable (URL, Settings) async throws -> String
    /// Writes the summaries earlier calls still owe, because the app quit or crashed
    /// while writing them, and returns their files.
    public var finishDueSummaries: @Sendable (Settings) async -> [URL]

    public init(
        paths: ListenerPaths,
        launchSettings: LoadedSettings,
        loadSettings: @escaping @Sendable () throws -> LoadedSettings,
        makeComponents: @escaping @Sendable (Settings, SessionCallbacks) throws -> SessionComponents,
        googleSetup: @escaping @Sendable (Settings) -> GoogleSetup,
        prepareOnDeviceSpeech:
            @escaping @Sendable (Settings, @escaping @Sendable (OnDeviceSpeechStatus) -> Void) async -> Void,
        hasAnthropicKey: @escaping @Sendable () -> Bool,
        sessionsDirectory: @escaping @Sendable (Settings) -> URL,
        importWebPage: @escaping @Sendable (URL, Settings) async throws -> String,
        finishDueSummaries: @escaping @Sendable (Settings) async -> [URL]
    ) {
        self.paths = paths
        self.launchSettings = launchSettings
        self.loadSettings = loadSettings
        self.makeComponents = makeComponents
        self.googleSetup = googleSetup
        self.prepareOnDeviceSpeech = prepareOnDeviceSpeech
        self.hasAnthropicKey = hasAnthropicKey
        self.sessionsDirectory = sessionsDirectory
        self.importWebPage = importWebPage
        self.finishDueSummaries = finishDueSummaries
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
