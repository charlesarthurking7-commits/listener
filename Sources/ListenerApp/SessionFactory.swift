import ClaudeAPI
import Foundation
import GoogleSpeech
import ListenerCore
import ListenerMac
import Synchronization
import os

/// Builds what a session runs on: audio sources, the speech and language model
/// providers, and the connections they share from call to call.
enum SessionFactory {
    struct Replay {
        var components: SessionComponents
        var sources: [ReplaySource]
    }

    /// One HTTP/2 connection to Anthropic for the whole app.
    private static let transport = URLSessionStreamingTransport()
    private static let googleProviders = GoogleProviderCache()

    static func live(settings: Settings, secrets: any SecretStore, callbacks: SessionCallbacks) throws
        -> SessionComponents
    {
        SessionComponents(
            sources: LiveAudioSources.make(settings: settings.capture, onEvent: callbacks.captureEvent),
            speech: try speech(settings, callbacks: callbacks),
            languageModel: languageModel(secrets)
        )
    }

    /// Both recordings through the full pipeline. With a script, recognition is
    /// scripted instead of going to a speech provider.
    static func replay(
        settings: Settings, secrets: any SecretStore, callbacks: SessionCallbacks,
        me: URL, them: URL, script: ConversationScript?, speed: Double
    ) throws -> Replay {
        let meSource = try ReplaySource(url: me, speaker: .me, speed: speed)
        let themSource = try ReplaySource(url: them, speaker: .them, speed: speed)
        let speech: any SpeechToTextProvider =
            if let script {
                ScriptedSpeechToText(script: script)
            } else {
                try self.speech(settings, callbacks: callbacks)
            }
        let components = SessionComponents(
            sources: [.me: meSource, .them: themSource],
            speech: speech,
            languageModel: languageModel(secrets)
        )
        return Replay(components: components, sources: [meSource, themSource])
    }

    /// A recorded call played into the app as if it were live. Its script stands in for
    /// speech-to-text, and canned answers can stand in for Claude.
    static func demo(_ demo: DemoCall, settings: Settings, secrets: any SecretStore, callbacks: SessionCallbacks)
        throws -> SessionComponents
    {
        let script = try ConversationScript.load(from: demo.folder.appendingPathComponent("script.json"))
        var components = try replay(
            settings: settings, secrets: demo.scriptedAnswers ? ChainedSecretStore([]) : secrets,
            callbacks: callbacks, me: demo.folder.appendingPathComponent("me.wav"),
            them: demo.folder.appendingPathComponent("them.wav"), script: script, speed: 1
        ).components
        if demo.scriptedAnswers {
            components.languageModel = DemoAnswers.model
        }
        return components
    }

    static func speech(_ settings: Settings, callbacks: SessionCallbacks) throws -> any SpeechToTextProvider {
        do {
            switch settings.speech.provider {
            case "google":
                return try googleProviders.provider(for: settings)
            case "apple":
                return try AppleSpeech.makeProvider(settings: settings, onModelState: callbacks.onDeviceSpeech)
            default:
                throw FactoryError(
                    "speech.provider \"\(settings.speech.provider)\" only works with listener replay --script. "
                        + "Set it to \"google\" or \"apple\" for live calls.")
            }
        } catch {
            Log.speech.error("Speech-to-text setup failed: \(ErrorText.describe(error), privacy: .public)")
            throw error
        }
    }

    /// Nil without an Anthropic key: the transcript still works, answers don't.
    static func languageModel(_ secrets: any SecretStore) -> (any LanguageModelProvider)? {
        guard let key = secrets.secret(.anthropicAPIKey) else {
            return nil
        }
        return ClaudeClient(apiKey: key, transport: transport)
    }

    /// Summaries that earlier calls still owe. The Keychain is only read when there is one.
    static func finishDueSummaries(_ settings: Settings, secrets: any SecretStore) async -> [URL] {
        let root = SessionStore.root(for: settings.storage)
        guard settings.summary.enabled, !SessionSummarizer.due(in: root).isEmpty, let model = languageModel(secrets)
        else {
            return []
        }
        return await SessionSummarizer.finishDue(in: root, settings: settings, model: model)
    }

    /// A web page as Markdown for a call's background, tidied by the quick model.
    static func importWebPage(_ url: URL, settings: Settings, secrets: any SecretStore) async throws -> String {
        guard let model = languageModel(secrets) else {
            throw FactoryError(
                "Reading a link needs an Anthropic API key. Copy the text from the page and press Paste instead.")
        }
        let importer = WebPageImporter(fetch: fetchPage, model: model, settings: settings.answers.webPageImport)
        return try await importer.importPage(url)
    }

    private static func fetchPage(_ url: URL) async throws -> WebPageImporter.Response {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (body, response) = try await URLSession.shared.data(for: request)
        return WebPageImporter.Response(
            body: body, status: (response as? HTTPURLResponse)?.statusCode ?? 200, mimeType: response.mimeType)
    }

    /// The Google project and credentials a call would use. Reads the credentials
    /// file but does not connect.
    static func googleSetup(_ settings: Settings) -> GoogleSetup {
        let configured = settings.speech.googleProjectID?.trimmingCharacters(in: .whitespaces)
        let project = configured?.isEmpty == false ? configured : nil
        do {
            let tokens = try GoogleCredentials.tokenProvider(for: settings.speech)
            return GoogleSetup(projectID: project ?? tokens.quotaProjectID, credentialsProblem: nil)
        } catch {
            return GoogleSetup(projectID: project, credentialsProblem: ErrorText.describe(error))
        }
    }

    /// Downloads Apple's on-device model for the configured language if needed.
    static func prepareOnDeviceSpeech(
        _ settings: Settings, report: @escaping @Sendable (OnDeviceSpeechStatus) -> Void
    ) async {
        do {
            try await AppleSpeech.installModel(languageCode: settings.speech.languageCode, onState: report)
        } catch {
            report(.failed(ErrorText.describe(error)))
        }
    }
}

/// Google's provider holds one HTTP/2 connection and is meant to live as long as the
/// app, so calls reuse it until the speech or turn settings change.
private final class GoogleProviderCache: Sendable {
    private let cached = Mutex<(speech: SpeechSettings, turns: TurnSettings, provider: GoogleSpeechProvider)?>(nil)

    func provider(for settings: Settings) throws -> GoogleSpeechProvider {
        try cached.withLock { cached in
            if let cached, cached.speech == settings.speech, cached.turns == settings.turns {
                return cached.provider
            }
            let tokens = try GoogleCredentials.tokenProvider(for: settings.speech)
            let provider = try GoogleSpeechProvider(
                settings: settings.speech, turns: settings.turns, tokenProvider: tokens)
            cached = (settings.speech, settings.turns, provider)
            return provider
        }
    }
}

struct FactoryError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
