import ArgumentParser

@main
struct ListenerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "listener",
        abstract: "Live meeting assistant.",
        subcommands: [SpikeCommand.self]
    )
}
