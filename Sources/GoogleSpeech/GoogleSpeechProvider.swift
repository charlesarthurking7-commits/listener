import GRPCCore
import GRPCNIOTransportHTTP2
import ListenerCore

/// Google Cloud Speech-to-Text v2 streaming recognition over gRPC.
///
/// One provider holds one HTTP/2 connection to the regional endpoint, shared by
/// every stream it opens. Create it once and keep it for the app's lifetime.
public final class GoogleSpeechProvider: SpeechToTextProvider {
    public let displayName: String
    private let client: any Google_Cloud_Speech_V2_Speech.ClientProtocol
    private let tokens: any AccessTokenProvider
    private let setup: RecognitionSetup
    private let tuning: StreamTuning
    private let shutdown: @Sendable () -> Void

    /// Connects over TLS to `settings.googleEndpoint`, verified against the system's
    /// trusted roots.
    ///
    /// - Throws: `GoogleSpeechError` with kind `.configuration` when the settings
    ///   cannot work: no project (neither `googleProjectID` nor the token provider's
    ///   quota project), an unknown endpointing sensitivity, or an endpoint that does
    ///   not match `googleLocation`.
    public convenience init(settings: SpeechSettings, tokenProvider: any AccessTokenProvider) throws {
        let setup = try RecognitionSetup(settings: settings, quotaProjectID: tokenProvider.quotaProjectID)
        let endpoint = try Endpoint(settings.googleEndpoint, location: settings.googleLocation)
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: endpoint.host, port: endpoint.port),
            transportSecurity: .tls)
        let grpc = GRPCClient(transport: transport)
        self.init(
            setup: setup,
            tokenProvider: tokenProvider,
            client: Google_Cloud_Speech_V2_Speech.Client(wrapping: grpc),
            tuning: StreamTuning(settings: settings),
            shutdown: { grpc.beginGracefulShutdown() })
        Task { try? await grpc.runConnections() }
    }

    /// For tests: talks to whatever `client` is connected to.
    convenience init(
        settings: SpeechSettings,
        tokenProvider: any AccessTokenProvider,
        client: any Google_Cloud_Speech_V2_Speech.ClientProtocol,
        tuning: StreamTuning
    ) throws {
        self.init(
            setup: try RecognitionSetup(settings: settings, quotaProjectID: tokenProvider.quotaProjectID),
            tokenProvider: tokenProvider,
            client: client,
            tuning: tuning,
            shutdown: {})
    }

    private init(
        setup: RecognitionSetup,
        tokenProvider: any AccessTokenProvider,
        client: any Google_Cloud_Speech_V2_Speech.ClientProtocol,
        tuning: StreamTuning,
        shutdown: @escaping @Sendable () -> Void
    ) {
        self.displayName = "Google \(setup.model) (\(setup.location))"
        self.setup = setup
        self.client = client
        self.tokens = tokenProvider
        self.tuning = tuning
        self.shutdown = shutdown
    }

    deinit {
        shutdown()
    }

    /// Fetches a token first, so missing or rejected credentials throw here, at
    /// Start. Everything that goes wrong later arrives through the stream's `events`.
    public func openStream(for speaker: Speaker) async throws -> any SpeechStream {
        _ = try await tokens.accessToken()
        let stream = GoogleSpeechStream(client: client, tokens: tokens, setup: setup, tuning: tuning)
        await stream.start()
        return stream
    }
}
