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
    public var makeComponents: @Sendable (Settings) throws -> SessionComponents
    /// Why speech-to-text credentials cannot be loaded, or nil when they can.
    public var speechCredentialsProblem: @Sendable (Settings) -> String?
    public var hasAnthropicKey: @Sendable () -> Bool
    public var sessionsDirectory: @Sendable (Settings) -> URL

    public init(
        paths: ListenerPaths,
        launchSettings: LoadedSettings,
        loadSettings: @escaping @Sendable () throws -> LoadedSettings,
        makeComponents: @escaping @Sendable (Settings) throws -> SessionComponents,
        speechCredentialsProblem: @escaping @Sendable (Settings) -> String?,
        hasAnthropicKey: @escaping @Sendable () -> Bool,
        sessionsDirectory: @escaping @Sendable (Settings) -> URL
    ) {
        self.paths = paths
        self.launchSettings = launchSettings
        self.loadSettings = loadSettings
        self.makeComponents = makeComponents
        self.speechCredentialsProblem = speechCredentialsProblem
        self.hasAnthropicKey = hasAnthropicKey
        self.sessionsDirectory = sessionsDirectory
    }
}
