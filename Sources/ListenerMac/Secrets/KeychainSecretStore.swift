import Foundation
import ListenerCore
import Security

/// Secrets kept in the login keychain as generic passwords with service "Listener"
/// and the secret's name as the account, e.g. ANTHROPIC_API_KEY. The same item can
/// be read with `security find-generic-password -s Listener -a ANTHROPIC_API_KEY -w`.
public struct KeychainSecretStore: SecretStore {
    public static let service = "Listener"

    public init() {}

    public func secret(_ name: SecretName) -> String? {
        var query = itemQuery(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                let error = KeychainError(status: status).description
                Log.secrets.error("Reading \(name.rawValue, privacy: .public) failed: \(error, privacy: .public)")
            }
            return nil
        }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Adds the secret, or replaces the value already stored under that name.
    public func store(_ value: String, for name: SecretName) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(itemQuery(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecItemNotFound {
            try check(status)
            return
        }
        var attributes = itemQuery(name)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "Listener \(name.rawValue)"
        try check(SecItemAdd(attributes as CFDictionary, nil))
    }

    /// Returns false if there was nothing to delete.
    @discardableResult
    public func delete(_ name: SecretName) throws -> Bool {
        let status = SecItemDelete(itemQuery(name) as CFDictionary)
        if status == errSecItemNotFound {
            return false
        }
        try check(status)
        return true
    }

    private func itemQuery(_ name: SecretName) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name.rawValue,
        ]
    }

    private func check(_ status: OSStatus) throws {
        if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// The secret stores the app and the CLI use, in the order they are asked.
public enum StandardSecrets {
    public static func chain(
        paths: ListenerPaths = .current,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> ChainedSecretStore {
        let localEnv = currentDirectory.appendingPathComponent(".env")
        return ChainedSecretStore([
            .init(name: "Keychain", store: KeychainSecretStore()),
            .init(name: "environment", store: EnvironmentSecretStore()),
            .init(name: paths.abbreviating(localEnv.path), store: DotEnvSecretStore(file: localEnv)),
            .init(name: paths.abbreviating(paths.envFile.path), store: DotEnvSecretStore(file: paths.envFile)),
        ])
    }
}
