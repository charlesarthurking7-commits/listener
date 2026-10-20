public enum SecretName: String, Sendable, CaseIterable {
    case anthropicAPIKey = "ANTHROPIC_API_KEY"
}

/// Where API keys come from. The app chains the Keychain, the process environment
/// and a .env file; tests use a dictionary. Implementations must never log values.
public protocol SecretStore: Sendable {
    func secret(_ name: SecretName) -> String?
}
