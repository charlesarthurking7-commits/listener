import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Sends one HTTP request. Injected so tests never touch the network.
typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Access tokens for user credentials, the `authorized_user` file that
/// `gcloud auth application-default login` writes. Exchanges the refresh token at
/// Google's token endpoint and caches the result until shortly before it expires.
public actor AuthorizedUserTokenProvider: AccessTokenProvider {
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let scope = "https://www.googleapis.com/auth/cloud-platform"
    /// A stream checks its token only when it opens, so a token with this much
    /// life left is still good for any stream that starts with it.
    static let refreshMargin: TimeInterval = 300

    public nonisolated let quotaProjectID: String?
    private let clientID: String
    private let clientSecret: String
    private let refreshToken: String
    private let http: HTTPClient
    private let now: @Sendable () -> Date

    private var cached: (token: String, expiresAt: Date)?
    private var inFlight: Task<(token: String, expiresAt: Date), any Error>?

    public init(clientID: String, clientSecret: String, refreshToken: String, quotaProjectID: String?) {
        self.init(
            clientID: clientID, clientSecret: clientSecret, refreshToken: refreshToken, quotaProjectID: quotaProjectID,
            http: urlSessionClient, now: Date.init)
    }

    init(
        clientID: String,
        clientSecret: String,
        refreshToken: String,
        quotaProjectID: String?,
        http: @escaping HTTPClient,
        now: @escaping @Sendable () -> Date
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.refreshToken = refreshToken
        self.quotaProjectID = quotaProjectID
        self.http = http
        self.now = now
    }

    public func accessToken() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSince(now()) > Self.refreshMargin {
            return cached.token
        }
        return try await refresh()
    }

    public func refreshAccessToken() async throws -> String {
        cached = nil
        return try await refresh()
    }

    /// Joins a refresh already under way, so two channels opening together make
    /// one request.
    private func refresh() async throws -> String {
        if let inFlight {
            return try await inFlight.value.token
        }
        let task = Task { try await requestToken() }
        inFlight = task
        defer { inFlight = nil }
        let result = try await task.value
        cached = result
        return result.token
    }

    private func requestToken() async throws -> (token: String, expiresAt: Date) {
        var request = URLRequest(url: Self.tokenEndpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded([
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("refresh_token", refreshToken),
            ("scope", Self.scope),
        ])

        let sentAt = now()
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http(request)
        } catch {
            throw GoogleAuthError(
                .unavailable, "Could not reach Google's token endpoint: \(error.localizedDescription)")
        }

        guard response.statusCode == 200 else {
            throw Self.error(status: response.statusCode, body: data)
        }
        guard let body = try? JSONDecoder().decode(TokenResponse.self, from: data), !body.accessToken.isEmpty else {
            throw GoogleAuthError(.unavailable, "Google's token endpoint returned an unreadable response")
        }
        return (body.accessToken, sentAt.addingTimeInterval(body.expiresIn ?? 3600))
    }

    static func error(status: Int, body: Data) -> GoogleAuthError {
        let detail = try? JSONDecoder().decode(TokenErrorResponse.self, from: body)
        let reason = [detail?.error, detail?.errorDescription].compactMap { $0 }.joined(separator: ": ")
        let suffix = reason.isEmpty ? "HTTP \(status)" : reason
        // 400 and 401 mean the refresh token or client is no good (invalid_grant,
        // invalid_client, invalid_scope). Anything else may pass.
        if status == 400 || status == 401 {
            return GoogleAuthError(
                .rejected,
                "Google rejected the stored credentials (\(suffix)). Run `gcloud auth application-default login` again."
            )
        }
        return GoogleAuthError(.unavailable, "Google's token endpoint failed (\(suffix))")
    }
}

private struct TokenResponse: Decodable {
    var accessToken: String
    var expiresIn: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

private struct TokenErrorResponse: Decodable {
    var error: String?
    var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private func formEncoded(_ fields: [(String, String)]) -> Data {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let body = fields.map { name, value in
        "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
    }
    return Data(body.joined(separator: "&").utf8)
}

private let urlSessionClient: HTTPClient = { request in
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    return (data, http)
}
