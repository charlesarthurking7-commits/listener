import ArgumentParser
import Foundation
import ListenerCore
import ListenerMac

struct SessionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions", abstract: "List saved calls, newest first.")

    @OptionGroup var options: GlobalOptions

    @Option(help: "How many calls to show.")
    var limit = 20

    func run() throws {
        let settings = try options.loadSettings().settings
        let root = SessionStore.root(for: settings.storage)
        let paths = ListenerPaths.current
        let sessions = SessionStore.list(in: root)
        if sessions.isEmpty {
            Console.write("No saved calls in \(paths.abbreviating(root.path)).\n")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM yyyy HH:mm"
        let rows = sessions.prefix(limit).map { session in
            [
                formatter.string(from: session.startedAt),
                session.duration.map(DisplayFormat.clock) ?? "-",
                String(session.turnCount),
                session.cost.map { DisplayFormat.cost($0.total) } ?? "-",
                session.hasSummary ? "yes" : "no",
                session.directory.lastPathComponent,
            ]
        }
        Console.write("Saved calls in \(paths.abbreviating(root.path)):\n\n")
        Console.write(
            TextTable.render(
                headers: ["Started", "Length", "Turns", "Cost", "Summary", "Folder"], rows: Array(rows),
                leftAligned: [0, 4, 5]))
        if sessions.count > limit {
            Console.write("\n\(sessions.count - limit) older calls not shown. Use --limit to see more.\n")
        }
    }
}

struct SummarizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summarize",
        abstract: "Write the summary and action items of a saved call again.",
        discussion: "Replaces summary.md in the session folder. listener sessions lists the folders."
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "The session folder, or its name in the sessions folder.")
    var session: String

    func run() async throws {
        let settings = try options.loadSettings().settings
        guard let model = SessionFactory.languageModel(StandardSecrets.chain()) else {
            throw ValidationError("No Anthropic API key. Run listener secrets set anthropic first.")
        }
        let directory = resolve(session, settings: settings)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw ValidationError("\(session) is not a session folder. listener sessions lists them.")
        }
        Console.write("Summarising \(directory.lastPathComponent) with \(settings.summary.model.model)...\n")
        let file = try await SessionSummarizer.summarize(directory: directory, settings: settings, model: model)
        Console.write("Summary: \(file.path)\n")
    }

    /// A path, or just a folder name from `listener sessions`.
    private func resolve(_ text: String, settings: Settings) -> URL {
        let path = ListenerPaths.current.expandingTilde(text)
        if path.contains("/") {
            return URL(fileURLWithPath: path)
        }
        return SessionStore.root(for: settings.storage).appendingPathComponent(path)
    }
}
