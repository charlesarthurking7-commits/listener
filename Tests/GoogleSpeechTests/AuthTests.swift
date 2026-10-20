import Foundation
import ListenerCore
import Synchronization
import Testing

@testable import GoogleSpeech

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A token endpoint that answers from a script and remembers what it was asked.
private actor FakeTokenEndpoint {
    private var replies: [(status: Int, body: String)]
    private(set) var requests: [URLRequest] = []
    private let delay: Duration

    init(_ replies: [(status: Int, body: String)], delay: Duration = .zero) {
        self.replies = replies
        self.delay = delay
    }

    func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        try await Task.sleep(for: delay)
        let reply = replies.count > 1 ? replies.removeFirst() : replies[0]
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        return (Data(reply.body.utf8), response)
    }

    var formFields: [String: String] {
        let body = String(decoding: requests.last?.httpBody ?? Data(), as: UTF8.self)
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            fields[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return fields
    }
}

/// A clock the test moves by hand.
private final class ManualClock: Sendable {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let offset = Mutex(0.0)

    var now: Date { start.addingTimeInterval(offset.withLock { $0 }) }

    func advance(by seconds: TimeInterval) {
        offset.withLock { $0 += seconds }
    }
}

struct AuthorizedUserTokenProviderTests {
    private let clock = ManualClock()

    private func provider(_ endpoint: FakeTokenEndpoint) -> AuthorizedUserTokenProvider {
        AuthorizedUserTokenProvider(
            clientID: "client.apps.googleusercontent.com",
            clientSecret: "s3cr3t+/=",
            refreshToken: "1//refresh",
            quotaProjectID: "quota-project",
            http: { try await endpoint.handle($0) },
            now: { [clock] in clock.now })
    }

    private static let ok = (
        status: 200, body: #"{"access_token":"ya29.first","expires_in":3599,"token_type":"Bearer"}"#
    )
    private static let second = (status: 200, body: #"{"access_token":"ya29.second","expires_in":3599}"#)

    @Test func exchangesTheRefreshTokenAndCachesTheResult() async throws {
        let endpoint = FakeTokenEndpoint([Self.ok, Self.second])
        let tokens = provider(endpoint)

        #expect(try await tokens.accessToken() == "ya29.first")
        #expect(try await tokens.accessToken() == "ya29.first")

        let requests = await endpoint.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(requests.first?.httpMethod == "POST")
        #expect(requests.first?.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(
            await endpoint.formFields == [
                "grant_type": "refresh_token",
                "client_id": "client.apps.googleusercontent.com",
                "client_secret": "s3cr3t+/=",
                "refresh_token": "1//refresh",
                "scope": "https://www.googleapis.com/auth/cloud-platform",
            ])
        #expect(tokens.quotaProjectID == "quota-project")
    }

    @Test func refreshesFiveMinutesBeforeExpiry() async throws {
        let endpoint = FakeTokenEndpoint([Self.ok, Self.second])
        let tokens = provider(endpoint)
        _ = try await tokens.accessToken()

        clock.advance(by: 3_200)
        #expect(try await tokens.accessToken() == "ya29.first")
        clock.advance(by: 100)
        #expect(try await tokens.accessToken() == "ya29.second")
        #expect(await endpoint.requests.count == 2)
    }

    @Test func refreshAccessTokenIgnoresTheCache() async throws {
        let endpoint = FakeTokenEndpoint([Self.ok, Self.second])
        let tokens = provider(endpoint)
        _ = try await tokens.accessToken()

        #expect(try await tokens.refreshAccessToken() == "ya29.second")
        #expect(try await tokens.accessToken() == "ya29.second")
    }

    @Test func concurrentCallersShareOneRequest() async throws {
        let endpoint = FakeTokenEndpoint([Self.ok], delay: .milliseconds(50))
        let tokens = provider(endpoint)

        async let first = tokens.accessToken()
        async let second = tokens.accessToken()
        #expect(try await [first, second] == ["ya29.first", "ya29.first"])
        #expect(await endpoint.requests.count == 1)
    }

    @Test func revokedCredentialsAskForANewLogin() async {
        let body = #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#
        let tokens = provider(FakeTokenEndpoint([(400, body)]))

        let error = await #expect(throws: GoogleAuthError.self) { try await tokens.accessToken() }
        #expect(error?.kind == .rejected)
        #expect(error?.message.contains("invalid_grant: Token has been expired or revoked.") == true)
        #expect(error?.message.contains("gcloud auth application-default login") == true)
    }

    @Test func serverErrorsMayPass() async {
        let tokens = provider(FakeTokenEndpoint([(503, "Service Unavailable")]))
        let error = await #expect(throws: GoogleAuthError.self) { try await tokens.accessToken() }
        #expect(error?.kind == .unavailable)
    }

    @Test func networkErrorsMayPass() async {
        let tokens = AuthorizedUserTokenProvider(
            clientID: "id", clientSecret: "secret", refreshToken: "refresh", quotaProjectID: nil,
            http: { _ in throw URLError(.notConnectedToInternet) }, now: Date.init)
        let error = await #expect(throws: GoogleAuthError.self) { try await tokens.accessToken() }
        #expect(error?.kind == .unavailable)
    }

    @Test func anUnreadableResponseIsAnError() async {
        let tokens = provider(FakeTokenEndpoint([(200, "<html>")]))
        let error = await #expect(throws: GoogleAuthError.self) { try await tokens.accessToken() }
        #expect(error?.kind == .unavailable)
    }
}

final class GcloudTokenProviderTests {
    private final class Runs: Sendable {
        let calls = Mutex<[(executable: URL, arguments: [String], environment: [String: String])]>([])
    }

    private let clock = ManualClock()
    private let runs = Runs()
    private let directory: URL

    init() throws {
        // A stand-in gcloud that is found on PATH but never actually run.
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gcloud = directory.appendingPathComponent("gcloud")
        try Data("#!/bin/sh\n".utf8).write(to: gcloud)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gcloud.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func provider(_ result: CommandResult) -> GcloudTokenProvider {
        GcloudTokenProvider(
            credentialsFile: "/keys/service-account.json",
            quotaProjectID: nil,
            environment: ["PATH": directory.path, "HOME": "/Users/me"],
            run: { [runs] executable, arguments, environment in
                runs.calls.withLock { $0.append((executable, arguments, environment)) }
                return result
            },
            now: { [clock] in clock.now })
    }

    private static func printed(_ output: String, status: Int32 = 0, errors: String = "") -> CommandResult {
        CommandResult(status: status, output: Data(output.utf8), errorOutput: Data(errors.utf8))
    }

    @Test func runsGcloudWithTheCredentialsFile() async throws {
        let tokens = provider(Self.printed("ya29.from-gcloud\n"))

        #expect(try await tokens.accessToken() == "ya29.from-gcloud")
        let call = try #require(runs.calls.withLock { $0.first })
        #expect(call.executable.path == directory.appendingPathComponent("gcloud").path)
        #expect(call.arguments == ["auth", "application-default", "print-access-token"])
        #expect(call.environment["GOOGLE_APPLICATION_CREDENTIALS"] == "/keys/service-account.json")
        #expect(call.environment["PATH"]?.hasPrefix(directory.path + ":/opt/homebrew/bin") == true)
    }

    @Test func cachesTheTokenForHalfAnHour() async throws {
        let tokens = provider(Self.printed("ya29.token"))
        _ = try await tokens.accessToken()
        clock.advance(by: 1_700)
        _ = try await tokens.accessToken()
        #expect(runs.calls.withLock { $0.count } == 1)

        clock.advance(by: 200)
        _ = try await tokens.accessToken()
        _ = try await tokens.refreshAccessToken()
        #expect(runs.calls.withLock { $0.count } == 3)
    }

    @Test func aFailedRunReportsStderrButNeverStdout() async {
        let tokens = provider(Self.printed("half-a-token", status: 1, errors: "ERROR: Reauthentication failed.\n"))
        let error = await #expect(throws: GoogleAuthError.self) { try await tokens.accessToken() }
        #expect(error?.kind == .rejected)
        #expect(error?.message.contains("ERROR: Reauthentication failed.") == true)
        #expect(error?.message.contains("half-a-token") == false)
    }

    @Test func refusesOutputThatIsNotAToken() async {
        let tokens = provider(Self.printed("Updates are available\nya29.token"))
        await #expect(throws: GoogleAuthError.self) { try await tokens.accessToken() }
    }

    @Test func looksForGcloudOnPathThenInTheUsualPlaces() {
        let environment = ["PATH": "/custom/bin:/usr/bin", "HOME": "/Users/me"]
        #expect(
            GcloudTokenProvider.searchPath(environment: environment) == [
                "/custom/bin", "/usr/bin", "/opt/homebrew/bin", "/opt/homebrew/share/google-cloud-sdk/bin",
                "/usr/local/bin", "/usr/local/share/google-cloud-sdk/bin", "/Users/me/google-cloud-sdk/bin", "/bin",
            ])
        #expect(
            GcloudTokenProvider.locateGcloud(environment: environment) {
                $0 == "/Users/me/google-cloud-sdk/bin/gcloud"
            }?.path == "/Users/me/google-cloud-sdk/bin/gcloud")
        #expect(GcloudTokenProvider.locateGcloud(environment: environment) { _ in false } == nil)
    }

    @Test func theProcessRunnerCollectsBothOutputsAndTheStatus() async throws {
        let result = try await runProcess(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "echo out; echo err >&2; exit 3"], [:])
        #expect(result.status == 3)
        #expect(String(decoding: result.output, as: UTF8.self) == "out\n")
        #expect(String(decoding: result.errorOutput, as: UTF8.self) == "err\n")
    }
}

struct GoogleCredentialsTests {
    private static let userFile = """
        {"type": "authorized_user", "client_id": "id", "client_secret": "secret",
         "refresh_token": "refresh", "quota_project_id": "file-project"}
        """

    private func tokens(
        _ file: String?,
        settings: SpeechSettings = SpeechSettings(),
        environment: [String: String] = ["HOME": "/Users/me"]
    ) throws -> any AccessTokenProvider {
        try GoogleCredentials.tokenProvider(for: settings, environment: environment) { path in
            guard let file else { throw CocoaError(.fileNoSuchFile) }
            return Data(file.utf8)
        }
    }

    @Test func userCredentialsAreRefreshedNatively() throws {
        let provider = try tokens(Self.userFile)
        #expect(provider is AuthorizedUserTokenProvider)
        #expect(provider.quotaProjectID == "file-project")
    }

    @Test func theSettingsProjectWinsOverTheFilesQuotaProject() throws {
        var settings = SpeechSettings()
        settings.googleProjectID = "settings-project"
        #expect(try tokens(Self.userFile, settings: settings).quotaProjectID == "settings-project")
    }

    @Test(arguments: ["service_account", "impersonated_service_account", "external_account"])
    func otherCredentialsGoThroughGcloud(_ type: String) throws {
        var settings = SpeechSettings()
        settings.googleProjectID = "settings-project"
        let provider = try tokens(#"{"type": "\#(type)"}"#, settings: settings)
        #expect(provider is GcloudTokenProvider)
        #expect(provider.quotaProjectID == nil)
    }

    @Test func aQuotaProjectInAServiceAccountFileIsKept() throws {
        let provider = try tokens(#"{"type": "service_account", "quota_project_id": "billing"}"#)
        #expect(provider.quotaProjectID == "billing")
    }

    @Test func aMissingFileSaysHowToLogIn() {
        let error = #expect(throws: GoogleAuthError.self) { try tokens(nil) }
        #expect(error?.kind == .missingCredentials)
        #expect(error?.message.contains("/Users/me/.config/gcloud/application_default_credentials.json") == true)
        #expect(error?.message.contains("gcloud auth application-default login") == true)
    }

    @Test func refusesFilesThatAreNotCredentials() {
        #expect(throws: GoogleAuthError.self) { try tokens("not json") }
        #expect(throws: GoogleAuthError.self) { try tokens(#"{"type": "authorized_user", "client_id": "id"}"#) }
    }

    @Test func picksTheFileLikeGooglesLibraries() {
        var settings = SpeechSettings()
        let environment = [
            "HOME": "/Users/me",
            "GOOGLE_APPLICATION_CREDENTIALS": "/keys/env.json",
            "CLOUDSDK_CONFIG": "/config/gcloud",
        ]
        #expect(
            GoogleCredentials.credentialsPath(settings: settings, environment: ["HOME": "/Users/me"])
                == "/Users/me/.config/gcloud/application_default_credentials.json")
        #expect(
            GoogleCredentials.credentialsPath(settings: settings, environment: ["HOME": "/h", "CLOUDSDK_CONFIG": "/c"])
                == "/c/application_default_credentials.json")
        #expect(GoogleCredentials.credentialsPath(settings: settings, environment: environment) == "/keys/env.json")

        settings.googleCredentialsFile = "~/keys/listener.json"
        #expect(
            GoogleCredentials.credentialsPath(settings: settings, environment: environment)
                == "/Users/me/keys/listener.json")
        settings.googleCredentialsFile = ""
        #expect(GoogleCredentials.credentialsPath(settings: settings, environment: environment) == "/keys/env.json")
    }
}
