import Foundation

public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// A response whose headers have arrived and whose body is still streaming in.
public struct HTTPStreamingResponse: Sendable {
    public var statusCode: Int
    /// Header names are lowercased.
    public var headers: [String: String]
    /// The body as lines without their terminators. Transports may drop empty lines
    /// (URLSession's `AsyncBytes.lines` does), so nothing may rely on seeing them.
    /// Ending the iteration early, or cancelling the task that iterates, cancels the request.
    public var lines: AsyncThrowingStream<String, any Error>

    public init(statusCode: Int, headers: [String: String], lines: AsyncThrowingStream<String, any Error>) {
        self.statusCode = statusCode
        self.headers = headers
        self.lines = lines
    }

    /// Reads the rest of the body as text, for error responses. Stops after `limit`
    /// bytes so a misbehaving server cannot make us buffer without bound.
    public func readBody(limit: Int = 64 * 1024) async throws -> String {
        var body = ""
        for try await line in lines {
            if !body.isEmpty {
                body += "\n"
            }
            body += line
            if body.utf8.count >= limit {
                break
            }
        }
        return body
    }
}

/// Sends one HTTP request and streams the response body. The macOS app uses
/// URLSession; tests use an in-memory fake.
public protocol HTTPStreamingTransport: Sendable {
    /// Returns once the status line and headers have arrived. Throws for connection
    /// failures, never for HTTP error statuses.
    func send(_ request: HTTPRequest) async throws -> HTTPStreamingResponse
}
