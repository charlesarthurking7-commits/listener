import Foundation

/// Supplies OAuth access tokens for Google Cloud. Implementations cache tokens and
/// must never log them.
public protocol AccessTokenProvider: Sendable {
    /// A token that stays valid for at least the next few minutes.
    func accessToken() async throws -> String

    /// Drops any cached token and fetches a new one. Called once when the server
    /// rejects a token, for example because it was revoked.
    func refreshAccessToken() async throws -> String

    /// The project billed for requests made with user credentials, sent as the
    /// `x-goog-user-project` header. Nil for credentials that bill their own project,
    /// such as service accounts.
    var quotaProjectID: String? { get }
}

/// One cached access token, fetched again once less than `margin` of its life is left.
/// Callers that arrive during a fetch join it, so two channels opening together make
/// one request.
actor TokenCache {
    typealias Token = (token: String, expiresAt: Date)

    private let margin: TimeInterval
    private let now: @Sendable () -> Date
    private let fetch: @Sendable () async throws -> Token
    private var cached: Token?
    private var inFlight: Task<Token, any Error>?

    init(
        margin: TimeInterval, now: @escaping @Sendable () -> Date, fetch: @escaping @Sendable () async throws -> Token
    ) {
        self.margin = margin
        self.now = now
        self.fetch = fetch
    }

    func token() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSince(now()) > margin {
            return cached.token
        }
        return try await refresh()
    }

    func refreshedToken() async throws -> String {
        cached = nil
        return try await refresh()
    }

    private func refresh() async throws -> String {
        if let inFlight {
            return try await inFlight.value.token
        }
        let task = Task { try await fetch() }
        inFlight = task
        defer { inFlight = nil }
        let result = try await task.value
        cached = result
        return result.token
    }
}

public struct GoogleAuthError: Error, LocalizedError, CustomStringConvertible, Equatable {
    public enum Kind: Sendable, Equatable {
        /// No credentials file where we looked, or it could not be read.
        case missingCredentials
        /// Google refused the stored credentials. Logging in again fixes it.
        case rejected
        /// The token endpoint or the gcloud CLI could not be reached or failed.
        /// Retrying may help.
        case unavailable
    }

    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}
