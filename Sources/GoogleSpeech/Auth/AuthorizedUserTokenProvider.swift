import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Sends one HTTP request. Injected so tests never touch the network.
typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Access tokens for user credentials, the `authorized_user` file that
/// `gcloud auth application-default login` writes. Exchanges the refresh token at
/// Google's token endpoint and caches the result until shortly before it expires.
public struct AuthorizedUserTokenProvider: AccessTokenProvider {
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let scope = "https://www.googleapis.com/auth/cloud-platform"
    /// A stream checks its token only when it opens, so a token with this much
    /// life left is still good for any stream that starts with it.
    static let refreshMargin: TimeInterval = 300

    public let quotaProjectID: String?
    private let cache: TokenCache

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
        self.quotaProjectID = quotaProjectID
        let form = formEncoded([
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("refresh_token", refreshToken),
            ("scope", Self.scope),
        ])
        cache = TokenCache(margin: Self.refreshMargin, now: now) {
            try await Self.requestToken(form: form, http: http, now: now)
        }
    }

    public func accessToken() async throws -> String {
        try await cache.token()
    }

    public func refreshAccessToken() async throws -> String {
        try await cache.refreshedToken()
    }

    private static func requestToken(
        form: Data, http: HTTPClient, now: @Sendable () -> Date
    ) async throws -> TokenCache.Token {
        var request = URLRequest(url: tokenEndpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form

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
            throw error(status: response.statusCode, body: data)
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
