import ArgumentParser
import Foundation

/// Decides between the menu bar app and the command line before any async code
/// runs. AppKit has to run from a plain synchronous main on the main thread: inside
/// an async main the run loop would be nested in a main-queue job, and the main
/// actor would never get to run anything else.
@main
enum Main {
    @MainActor
    static func main() {
        // Finder used to pass a -psn_ process serial number argument to apps.
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
        let command: any ParsableCommand
        do {
            command = try ListenerCommand.parseAsRoot(Array(arguments))
        } catch {
            ListenerCommand.exit(withError: error)
        }
        if let app = command as? ListenerCommand {
            app.launchApp()
        }
        if let demo = command as? DemoCommand {
            demo.launchApp()
        }

        Task {
            await ListenerCommand.main(Array(arguments))
            exit(0)
        }
        // What an async main does on macOS: keep the main run loop going, which
        // also drains the main queue, until a command calls exit.
        CFRunLoopRun()
        exit(0)
    }
}
