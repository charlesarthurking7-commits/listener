import Foundation
import ListenerCore
import Observation

/// settings.json for every page of the main window that changes it. Each change reads
/// the file again first, so an edit made in a text editor meanwhile is kept, then is
/// checked the way loading checks it and written straight back.
@MainActor
@Observable
final class SettingsStore {
    private(set) var settings: Settings
    /// Why the file can't be read, such as a typo in hand-written JSON. Nothing is
    /// written over it until it is fixed.
    private(set) var problem: String?
    /// Why the last change was refused, until the next one.
    var message: String?

    /// The settings Listener started with, for changes that only apply at the next start.
    let atLaunch: Settings
    private let environment: AppEnvironment
    /// Told after every change that was written, to apply it where it can apply at once.
    @ObservationIgnored var onChange: (@MainActor (Settings) -> Void)?

    init(environment: AppEnvironment) {
        self.environment = environment
        atLaunch = environment.launchSettings.settings
        settings = atLaunch
    }

    var file: URL { environment.settingsFile }

    func reload() {
        do {
            settings = try document().settings
            problem = nil
        } catch {
            problem = ErrorText.describe(error)
        }
    }

    /// Sets one value, or takes it out of the file when nil, which puts back its default.
    func set(_ value: JSONValue?, at path: String) {
        do {
            var document = try document()
            try document.set(value, at: path.split(separator: ".").map(String.init))
            try document.write()
            settings = document.settings
            problem = nil
            message = nil
            onChange?(settings)
        } catch let error as SettingsError {
            message = error.problems.joined(separator: " ")
        } catch {
            message = "Could not save the setting: \(ErrorText.describe(error))"
        }
    }

    func set(_ value: Bool, at path: String) {
        set(.bool(value), at: path)
    }

    func set(_ value: String, at path: String) {
        set(.string(value), at: path)
    }

    func set(_ value: Int, at path: String) {
        set(.integer(value), at: path)
    }

    func set(_ value: Double, at path: String) {
        set(.number(value), at: path)
    }

    func set(_ values: [String], at path: String) {
        set(.array(values.map(JSONValue.string)), at: path)
    }

    private func document() throws -> SettingsDocument {
        try SettingsDocument(file: environment.settingsFile, paths: environment.paths)
    }
}
