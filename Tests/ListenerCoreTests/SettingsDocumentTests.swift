import Foundation
import Testing

@testable import ListenerCore

final class SettingsDocumentTests {
    private let home: URL
    private let paths: ListenerPaths

    init() throws {
        home = try temporaryDirectory("home")
        paths = ListenerPaths(home: home)
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeFile(_ json: String) throws {
        try FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: paths.settingsFile)
    }

    private func fileText() throws -> String {
        try String(contentsOf: paths.settingsFile, encoding: .utf8)
    }

    @Test func aMissingFileIsEmptyAndWritingCreatesIt() throws {
        var document = try SettingsDocument(paths: paths)
        #expect(document.file == paths.settingsFile)
        #expect(document.contents == .object([:]) && document.settings == Settings() && document.warnings.isEmpty)

        try document.set(.bool(false), at: ["window", "alwaysOnTop"])
        try document.set(.string("~/Calls/2026"), at: ["storage", "directory"])
        #expect(!document.settings.window.alwaysOnTop)
        try document.write()
        #expect(
            try fileText() == """
                {
                  "storage" : {
                    "directory" : "~/Calls/2026"
                  },
                  "window" : {
                    "alwaysOnTop" : false
                  }
                }

                """)
        #expect(try SettingsLoader(paths: paths).load().settings == document.settings)
        #expect(try SettingsDocument(paths: paths) == document)
    }

    @Test func tildesStayInTheFile() throws {
        try writeFile(#"{"storage": {"directory": "~/Calls"}}"#)
        var document = try SettingsDocument(paths: paths)
        #expect(document.settings.storage.directory == home.appendingPathComponent("Calls").path)
        try document.set(.integer(7), at: ["storage", "retentionDays"])
        try document.write()
        #expect(try fileText().contains(#""directory" : "~/Calls""#))
    }

    @Test func removingAValueGoesBackToTheDefault() throws {
        try writeFile(#"{"window": {"opacity": 0.5}, "turns": {"silenceMs": 900, "minSpeechMs": 100}}"#)
        var document = try SettingsDocument(paths: paths)
        #expect(document.settings.window.opacity == 0.5)

        try document.set(nil, at: ["window", "opacity"])
        try document.set(nil, at: ["turns", "silenceMs"])
        try document.set(nil, at: ["speech", "model"])
        #expect(document.settings.window.opacity == WindowSettings().opacity)
        #expect(document.contents == .object(["turns": .object(["minSpeechMs": .integer(100)])]))
    }

    @Test func anInvalidValueIsRefusedAndChangesNothing() throws {
        try writeFile(#"{"window": {"opacity": 0.5}}"#)
        var document = try SettingsDocument(paths: paths)
        let before = document

        let range = try #require(throws: SettingsError.self) {
            try document.set(.number(5), at: ["window", "opacity"])
        }
        #expect(range.problems == ["window.opacity must be between 0.2 and 1"])
        #expect(range.source == "~/Library/Application Support/Listener/settings.json")
        let type = try #require(throws: SettingsError.self) {
            try document.set(.string("yes"), at: ["window", "alwaysOnTop"])
        }
        #expect(type.problems == ["window.alwaysOnTop should be true or false, but is \"yes\""])
        #expect(throws: SettingsError.self) { try document.set(.string("ctrl+option+a"), at: ["hotkeys", "recap"]) }
        #expect(document == before)
    }

    @Test func unknownKeysAreKept() throws {
        try writeFile(#"{"colour": "red", "storage": {"retentionDay": 5}, "notes": {"url": "https://example.com/a"}}"#)
        var document = try SettingsDocument(paths: paths)
        #expect(document.warnings.count == 3)
        try document.set(.bool(true), at: ["storage", "saveAudio"])
        try document.write()
        let written = try JSONValue(parsing: Data(contentsOf: paths.settingsFile))
        #expect(
            written
                == .object([
                    "colour": .string("red"),
                    "notes": .object(["url": .string("https://example.com/a")]),
                    "storage": .object(["retentionDay": .integer(5), "saveAudio": .bool(true)]),
                ]))
        #expect(try fileText().contains("https://example.com/a"))
    }

    @Test func aFileTheLoaderWouldRefuseCannotBeOpened() throws {
        try writeFile(#"{"window": {"opacity": }"#)
        let broken = try #require(throws: SettingsError.self) { try SettingsDocument(paths: paths) }
        #expect(broken.problems.count == 1 && broken.problems[0].hasPrefix("is not valid JSON ("))

        try writeFile("[1, 2]")
        let list = try #require(throws: SettingsError.self) { try SettingsDocument(paths: paths) }
        #expect(list.problems == ["must hold a JSON object, { ... }, at the top level"])
    }

    @Test func writingCreatesTheFolder() throws {
        let file = home.appendingPathComponent("elsewhere/deeper/settings.json")
        var document = try SettingsDocument(file: file, paths: paths)
        try document.set(.integer(500), at: ["turns", "silenceMs"])
        try document.write()
        #expect(try SettingsLoader(paths: paths).load(explicitPath: file.path).settings.turns.silenceMs == 500)
    }
}
