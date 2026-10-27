import Foundation

/// settings.json as the Settings page edits it: one value at a time, each change checked
/// the way SettingsLoader checks the file, then written back with every key the user had,
/// unknown ones included. Values stay as written, so "~/Calls" stays "~/Calls" in the file.
public struct SettingsDocument: Sendable, Equatable {
    public let file: URL
    /// What the file itself holds: only the keys the user set.
    public private(set) var contents: JSONValue
    /// The file over the defaults, with `~` expanded, as SettingsLoader loads it.
    public private(set) var settings: Settings
    /// Such as misspelt keys, which are kept but ignored.
    public private(set) var warnings: [String]
    private let paths: ListenerPaths

    /// Opens `file`, by default settings.json in the support folder. A missing file reads
    /// as an empty one, and `write()` creates it. A file the loader would refuse throws
    /// the loader's SettingsError.
    public init(file: URL? = nil, paths: ListenerPaths = .current) throws {
        let file = file ?? paths.settingsFile
        let source = paths.abbreviating(file.path)
        let contents =
            FileManager.default.fileExists(atPath: file.path)
            ? try SettingsLoader.read(file, source: source) : .object([:])
        let loaded = try SettingsLoader(paths: paths).settings(from: contents, source: source)
        self.file = file
        self.contents = contents
        settings = loaded.settings
        warnings = loaded.warnings
        self.paths = paths
    }

    /// Sets the value at `path`, such as ["window", "alwaysOnTop"], or takes it out, back
    /// to its default, when `value` is nil. A change that would make the file fail to load
    /// throws a SettingsError naming the problem and leaves the document as it was.
    public mutating func set(_ value: JSONValue?, at path: [String]) throws {
        precondition(!path.isEmpty, "a setting needs a key")
        let changed = contents.setting(value, at: path)
        let loaded = try SettingsLoader(paths: paths).settings(from: changed, source: paths.abbreviating(file.path))
        contents = changed
        settings = loaded.settings
        warnings = loaded.warnings
    }

    /// Writes the file atomically, creating its folder if needed.
    public func write() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try SettingsLoader.fileData(contents)
        data.append(UInt8(ascii: "\n"))
        try data.write(to: file, options: .atomic)
    }
}
