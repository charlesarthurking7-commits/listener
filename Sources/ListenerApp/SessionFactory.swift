import ClaudeAPI
import Foundation
import GoogleSpeech
import ListenerCore
import ListenerMac

/// The one place that builds audio sources, providers and session storage. Every
/// concrete type from the capture, speech, Claude and session-store code is named
/// here and nowhere else in the app, so a rename touches this file only.
enum SessionFactory {
    struct Replay {
        var components: SessionComponents
        var sources: [ReplaySource]
    }

    static func live(settings: Settings, secrets: any SecretStore) throws -> SessionComponents {
        SessionComponents(
            sources: LiveAudioSources.make(settings: settings.capture),
            speech: try speech(settings),
            languageModel: languageModel(secrets)
        )
    }

    /// Both recordings through the full pipeline. With a script, recognition is
    /// scripted instead of going to Google.
    static func replay(
        settings: Settings, secrets: any SecretStore, me: URL, them: URL, script: ConversationScript?, speed: Double
    ) throws -> Replay {
        let meSource = try ReplaySource(url: me, speaker: .me, speed: speed)
        let themSource = try ReplaySource(url: them, speaker: .them, speed: speed)
        let speech: any SpeechToTextProvider =
            if let script {
                ScriptedSpeechToText(script: script)
            } else {
                try self.speech(settings)
            }
        let components = SessionComponents(
            sources: [.me: meSource, .them: themSource],
            speech: speech,
            languageModel: languageModel(secrets)
        )
        return Replay(components: components, sources: [meSource, themSource])
    }

    static func speech(_ settings: Settings) throws -> any SpeechToTextProvider {
        guard settings.speech.provider == "google" else {
            throw FactoryError(
                "speech.provider \"\(settings.speech.provider)\" only works with listener replay --script. "
                    + "Set it to \"google\" for live calls.")
        }
        let tokens = try GoogleCredentials.tokenProvider(settings: settings.speech)
        return GoogleSpeechProvider(settings: settings.speech, tokenProvider: tokens)
    }

    /// Nil without an Anthropic key: the transcript still works, answers don't.
    static func languageModel(_ secrets: any SecretStore) -> (any LanguageModelProvider)? {
        guard let key = secrets.secret(.anthropicAPIKey) else {
            return nil
        }
        return ClaudeClient(apiKey: key, transport: URLSessionStreamingTransport())
    }

    /// Why Google credentials can't be loaded, or nil when they can.
    static func speechCredentialsProblem(_ settings: Settings) -> String? {
        guard settings.speech.provider == "google" else {
            return nil
        }
        do {
            _ = try GoogleCredentials.tokenProvider(settings: settings.speech)
            return nil
        } catch {
            return ErrorText.describe(error)
        }
    }

    static func sessionsRoot(_ settings: Settings) -> URL {
        SessionStore.root(for: settings.storage)
    }

    static func listSessions(_ settings: Settings) -> [SavedSession] {
        SessionStore.list(in: sessionsRoot(settings))
    }

    @discardableResult
    static func deleteExpiredSessions(_ settings: Settings) throws -> [URL] {
        try SessionStore.deleteExpired(in: sessionsRoot(settings), retentionDays: settings.storage.retentionDays)
    }

    static func summarize(directory: URL, settings: Settings, model: any LanguageModelProvider) async throws -> URL {
        try await SessionSummarizer.summarize(directory: directory, settings: settings, model: model)
    }
}

struct FactoryError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
