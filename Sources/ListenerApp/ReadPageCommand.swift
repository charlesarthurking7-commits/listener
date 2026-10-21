import ArgumentParser
import Foundation
import ListenerCore
import ListenerMac

struct ReadPageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read-page",
        abstract: "Read a web page the way Paste does and print the document it would save.",
        discussion: """
            Useful for checking what Listener gets from a page before a call.
            Some sites, LinkedIn among them, need a sign-in; for those, copy the text instead.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "The page's address, e.g. a job posting.")
    var url: String

    func validate() throws {
        guard let url = URL(string: url), ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw ValidationError("\(url) is not a web address.")
        }
    }

    func run() async throws {
        let settings = try options.loadSettings().settings
        let markdown = try await SessionFactory.importWebPage(
            URL(string: url)!, settings: settings, secrets: StandardSecrets.chain())
        Console.write(markdown)
    }
}
