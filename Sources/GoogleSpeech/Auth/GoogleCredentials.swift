import Foundation
import ListenerCore

/// Finds Google credentials the way Google's own libraries do (Application Default
/// Credentials) and picks a token provider for them.
public enum GoogleCredentials {
    /// Picks the credentials file: `speech.googleCredentialsFile`, then
    /// GOOGLE_APPLICATION_CREDENTIALS, then gcloud's ADC file. User credentials
    /// (`authorized_user`, what `gcloud auth application-default login` writes) are
    /// refreshed natively; every other type goes through the gcloud CLI.
    ///
    /// For user credentials the quota project is `speech.googleProjectID`, or else the
    /// file's `quota_project_id`. Other credentials use only the file's.
    public static func tokenProvider(
        for settings: SpeechSettings,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any AccessTokenProvider {
        try tokenProvider(for: settings, environment: environment) { path in
            try Data(contentsOf: URL(fileURLWithPath: path))
        }
    }

    static func tokenProvider(
        for settings: SpeechSettings,
        environment: [String: String],
        readFile: (String) throws -> Data
    ) throws -> any AccessTokenProvider {
        let path = credentialsPath(settings: settings, environment: environment)
        let data: Data
        do {
            data = try readFile(path)
        } catch {
            throw GoogleAuthError(
                .missingCredentials,
                "No Google credentials at \(path). Run `gcloud auth application-default login`, "
                    + "or set speech.googleCredentialsFile.")
        }
        guard let file = try? JSONDecoder().decode(CredentialsFile.self, from: data) else {
            throw GoogleAuthError(.missingCredentials, "\(path) is not a Google credentials file")
        }

        guard file.type == "authorized_user" else {
            // Service accounts bill their own project. Sending x-goog-user-project for
            // them would need an extra permission (serviceusage.services.use), so only
            // do it when the file asks for it, as Google's libraries do.
            return GcloudTokenProvider(
                credentialsFile: path, quotaProjectID: file.quotaProjectID.nilIfBlank, environment: environment)
        }
        guard let clientID = file.clientID, let clientSecret = file.clientSecret,
            let refreshToken = file.refreshToken
        else {
            throw GoogleAuthError(
                .missingCredentials,
                "\(path) is missing client_id, client_secret or refresh_token. "
                    + "Run `gcloud auth application-default login` again.")
        }
        return AuthorizedUserTokenProvider(
            clientID: clientID,
            clientSecret: clientSecret,
            refreshToken: refreshToken,
            quotaProjectID: settings.googleProjectID.nilIfBlank ?? file.quotaProjectID.nilIfBlank)
    }

    static func credentialsPath(settings: SpeechSettings, environment: [String: String]) -> String {
        let home = environment["HOME"] ?? NSHomeDirectory()
        if let configured = settings.googleCredentialsFile.nilIfBlank {
            return ListenerPaths(home: URL(fileURLWithPath: home)).expandingTilde(configured)
        }
        if let fromEnvironment = environment["GOOGLE_APPLICATION_CREDENTIALS"].nilIfBlank {
            return fromEnvironment
        }
        let configDirectory = environment["CLOUDSDK_CONFIG"].nilIfBlank ?? "\(home)/.config/gcloud"
        return "\(configDirectory)/application_default_credentials.json"
    }
}

/// The fields we use from any of the ADC file types.
struct CredentialsFile: Decodable {
    var type: String
    var clientID: String?
    var clientSecret: String?
    var refreshToken: String?
    var quotaProjectID: String?

    enum CodingKeys: String, CodingKey {
        case type
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case refreshToken = "refresh_token"
        case quotaProjectID = "quota_project_id"
    }
}

extension Optional where Wrapped == String {
    /// Nil for a missing or blank value, so an empty settings field means "not set".
    var nilIfBlank: String? {
        guard let self, !self.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return self
    }
}
