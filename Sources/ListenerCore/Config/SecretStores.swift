import Foundation

/// Secrets from environment variables, e.g. ANTHROPIC_API_KEY.
public struct EnvironmentSecretStore: SecretStore {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func secret(_ name: SecretName) -> String? {
        nonEmpty(environment[name.rawValue])
    }
}

/// Secrets from a .env file. The file is read on every lookup, so a key added while
/// the app runs is picked up by the next session. A missing file holds no secrets.
public struct DotEnvSecretStore: SecretStore {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func secret(_ name: SecretName) -> String? {
        guard let data = FileManager.default.contents(atPath: file.path) else {
            return nil
        }
        return nonEmpty(DotEnv.parse(String(decoding: data, as: UTF8.self))[name.rawValue])
    }
}

/// Asks each store in turn and returns the first value found.
public struct ChainedSecretStore: SecretStore {
    public struct Link: Sendable {
        /// Where the value came from, for display, e.g. "Keychain" or "~/.../.env".
        public var name: String
        public var store: any SecretStore

        public init(name: String, store: any SecretStore) {
            self.name = name
            self.store = store
        }
    }

    public var links: [Link]

    public init(_ links: [Link]) {
        self.links = links
    }

    public func secret(_ name: SecretName) -> String? {
        lookup(name)?.value
    }

    /// The value and the name of the store that had it.
    public func lookup(_ name: SecretName) -> (value: String, source: String)? {
        for link in links {
            if let value = link.store.secret(name) {
                return (value, link.name)
            }
        }
        return nil
    }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}
