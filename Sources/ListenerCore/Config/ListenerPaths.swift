import Foundation

/// Where Listener keeps its own files. Built from a home directory so tests can
/// point it anywhere.
public struct ListenerPaths: Sendable, Equatable {
    public var home: URL

    public init(home: URL) {
        self.home = home
    }

    public static var current: ListenerPaths {
        ListenerPaths(home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    /// ~/Library/Application Support/Listener
    public var supportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/Listener", isDirectory: true)
    }

    public var settingsFile: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    public var envFile: URL {
        supportDirectory.appendingPathComponent(".env")
    }

    /// The words dictation learned from corrections. See LearnedDictionary.
    public var dictionaryFile: URL {
        supportDirectory.appendingPathComponent("dictionary.txt")
    }

    /// How much has been dictated, per day. See DictationStats.
    public var dictationStatsFile: URL {
        supportDirectory.appendingPathComponent("dictation-stats.json")
    }

    /// "~" and "~/..." resolved against `home`. Other paths are returned unchanged.
    public func expandingTilde(_ path: String) -> String {
        if path == "~" {
            return home.path
        }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    /// Replaces the home directory prefix with "~" for display.
    public func abbreviating(_ path: String) -> String {
        let homePath = home.standardizedFileURL.path
        if path == homePath {
            return "~"
        }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }
}
