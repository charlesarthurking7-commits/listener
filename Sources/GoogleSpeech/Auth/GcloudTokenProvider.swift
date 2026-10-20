import Foundation

struct CommandResult: Sendable {
    var status: Int32
    var output: Data
    var errorOutput: Data
}

/// Runs a program and collects what it printed. Injected so tests never spawn gcloud.
typealias CommandRunner =
    @Sendable (_ executable: URL, _ arguments: [String], _ environment: [String: String])
    async throws -> CommandResult

/// Access tokens from `gcloud auth application-default print-access-token`. Slower
/// than the native refresh (gcloud takes a second or two to start), but it handles
/// every kind of credentials file gcloud understands: service account keys, service
/// account impersonation and workload identity federation.
public actor GcloudTokenProvider: AccessTokenProvider {
    /// gcloud refreshes the token on every call (see print_access_token.py in the
    /// Cloud SDK), so a fresh one has a full hour of life. Half an hour leaves room.
    static let cacheLifetime: TimeInterval = 1800

    public nonisolated let quotaProjectID: String?
    private let credentialsFile: String?
    private let environment: [String: String]
    private let run: CommandRunner
    private let now: @Sendable () -> Date

    private var cached: (token: String, fetchedAt: Date)?
    private var inFlight: Task<String, any Error>?

    /// - Parameters:
    ///   - credentialsFile: Passed to gcloud as GOOGLE_APPLICATION_CREDENTIALS. Nil uses
    ///     gcloud's own default.
    ///   - quotaProjectID: Sent as `x-goog-user-project`, if the credentials need one.
    public init(
        credentialsFile: String?,
        quotaProjectID: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(
            credentialsFile: credentialsFile, quotaProjectID: quotaProjectID, environment: environment,
            run: runProcess, now: Date.init)
    }

    init(
        credentialsFile: String?,
        quotaProjectID: String?,
        environment: [String: String],
        run: @escaping CommandRunner,
        now: @escaping @Sendable () -> Date
    ) {
        self.credentialsFile = credentialsFile
        self.quotaProjectID = quotaProjectID
        self.environment = environment
        self.run = run
        self.now = now
    }

    public func accessToken() async throws -> String {
        if let cached, now().timeIntervalSince(cached.fetchedAt) < Self.cacheLifetime {
            return cached.token
        }
        return try await refresh()
    }

    public func refreshAccessToken() async throws -> String {
        cached = nil
        return try await refresh()
    }

    private func refresh() async throws -> String {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await printAccessToken() }
        inFlight = task
        defer { inFlight = nil }
        let fetchedAt = now()
        let token = try await task.value
        cached = (token, fetchedAt)
        return token
    }

    private func printAccessToken() async throws -> String {
        guard let gcloud = Self.locateGcloud(environment: environment) else {
            throw GoogleAuthError(
                .missingCredentials,
                "These Google credentials need the gcloud CLI, which was not found. Install the Google Cloud SDK.")
        }
        var childEnvironment = environment
        childEnvironment["PATH"] = Self.searchPath(environment: environment).joined(separator: ":")
        if let credentialsFile {
            childEnvironment["GOOGLE_APPLICATION_CREDENTIALS"] = credentialsFile
        }

        let result: CommandResult
        do {
            result = try await run(gcloud, ["auth", "application-default", "print-access-token"], childEnvironment)
        } catch {
            throw GoogleAuthError(.unavailable, "Could not run gcloud: \(error.localizedDescription)")
        }

        // stdout holds the token, so only stderr ever goes into a message.
        guard result.status == 0 else {
            let detail = String(decoding: result.errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GoogleAuthError(
                .rejected,
                "gcloud could not print an access token (exit \(result.status)): \(detail)")
        }
        let token = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else {
            throw GoogleAuthError(.unavailable, "gcloud printed something that is not an access token")
        }
        return token
    }

    /// An app started from Finder gets a minimal PATH, so also look where the Cloud
    /// SDK installer and Homebrew put gcloud.
    static func searchPath(environment: [String: String]) -> [String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let common = [
            "/opt/homebrew/bin",
            "/opt/homebrew/share/google-cloud-sdk/bin",
            "/usr/local/bin",
            "/usr/local/share/google-cloud-sdk/bin",
            "\(home)/google-cloud-sdk/bin",
            "/usr/bin",
            "/bin",
        ]
        var seen = Set<String>()
        return (inherited + common).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func locateGcloud(
        environment: [String: String],
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        searchPath(environment: environment)
            .map { URL(fileURLWithPath: $0).appendingPathComponent("gcloud").path }
            .first(where: isExecutable)
            .map { URL(fileURLWithPath: $0) }
    }
}

/// Runs the command on a plain thread rather than the concurrency pool, because
/// waiting on a pipe blocks. Gives up after 30 seconds so a hung gcloud cannot
/// stall a reconnect forever.
let runProcess: CommandRunner = { executable, arguments, environment in
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            let errorOutput = Pipe()
            process.standardOutput = output
            process.standardError = errorOutput
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            let pid = process.processIdentifier
            let watchdog = DispatchWorkItem { kill(pid, SIGTERM) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
            // Both outputs are a few hundred bytes, far below the pipe buffer, so
            // reading them one after the other cannot deadlock.
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            let errors = errorOutput.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            continuation.resume(
                returning: CommandResult(status: process.terminationStatus, output: printed, errorOutput: errors))
        }
    }
}
