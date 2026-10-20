import ClaudeAPI
import Foundation

/// HTTPS for the Anthropic client. Keep one instance for the whole app: requests then
/// share URLSession's HTTP/2 connection, so only the first pays for DNS and the TLS
/// handshake.
public final class URLSessionStreamingTransport: HTTPStreamingTransport {
    private let session: URLSession
    private let readTimeout: TimeInterval

    /// - Parameters:
    ///   - readTimeout: the longest wait for more data. Generous, because a model can
    ///     think for a while between events; `ClaudeClient` puts a short limit on the
    ///     wait for the response headers, which is where a dead connection shows.
    ///   - maxDuration: the longest a whole request may take, summaries included.
    public init(readTimeout: TimeInterval = 60, maxDuration: TimeInterval = 600) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = readTimeout
        configuration.timeoutIntervalForResource = maxDuration
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        self.readTimeout = readTimeout
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        var urlRequest = URLRequest(
            url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: readTimeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let value = value as? String {
                headers[name.lowercased()] = value
            }
        }

        // The reader task owns the transfer. Cancelling the consumer, or dropping the
        // stream, terminates the stream, which cancels the reader and with it the request.
        let (lines, continuation) = AsyncThrowingStream.makeStream(of: String.self, throwing: (any Error).self)
        let reader = Task {
            do {
                for try await line in bytes.lines {
                    continuation.yield(line)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in reader.cancel() }
        return HTTPStreamingResponse(statusCode: http.statusCode, headers: headers, lines: lines)
    }
}
