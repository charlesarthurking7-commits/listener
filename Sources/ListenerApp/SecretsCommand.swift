import ArgumentParser
import Foundation
import ListenerCore
import ListenerMac

struct SecretsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secrets",
        abstract: "Store API keys in the Keychain, or see where they come from.",
        subcommands: [SetSecretCommand.self, DeleteSecretCommand.self, SecretStatusCommand.self]
    )
}

enum SecretOption: String, ExpressibleByArgument, CaseIterable {
    case anthropic

    var name: SecretName {
        switch self {
        case .anthropic: .anthropicAPIKey
        }
    }

    var title: String {
        switch self {
        case .anthropic: "Anthropic API key"
        }
    }
}

struct SetSecretCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Read a key from the terminal (without showing it) and store it in the Keychain.",
        discussion: "Also reads from a pipe: pbpaste | listener secrets set anthropic"
    )

    @Argument(help: "Which key: anthropic.")
    var secret: SecretOption

    func run() throws {
        if Console.inputIsTerminal {
            Console.write("Paste your \(secret.title) and press Enter. It will not be shown: ")
        }
        guard let value = Console.readHiddenLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else {
            throw ValidationError("No key was entered, so nothing was stored.")
        }
        if secret == .anthropic && !value.hasPrefix("sk-ant-") {
            Console.error("That does not look like an Anthropic key (they start with sk-ant-). Storing it anyway.")
        }
        try KeychainSecretStore().store(value, for: secret.name)
        Console.write(
            "Stored in the Keychain (service \"\(KeychainSecretStore.service)\", account \"\(secret.name.rawValue)\").\n"
        )
    }
}

struct DeleteSecretCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Remove a key from the Keychain.")

    @Argument(help: "Which key: anthropic.")
    var secret: SecretOption

    func run() throws {
        if try KeychainSecretStore().delete(secret.name) {
            Console.write("Removed the \(secret.title) from the Keychain.\n")
        } else {
            Console.write("The Keychain had no \(secret.title).\n")
        }
    }
}

struct SecretStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show where each key is found. Never prints the keys.")

    func run() throws {
        let chain = StandardSecrets.chain()
        for secret in SecretOption.allCases {
            if let found = chain.lookup(secret.name) {
                Console.write("\(secret.title): found in \(found.source)\n")
            } else {
                let places = chain.links.map(\.name).joined(separator: ", ")
                Console.write("\(secret.title): not found (looked in \(places))\n")
            }
        }
    }
}
