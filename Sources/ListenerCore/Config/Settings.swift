/// Every tunable in one place. Loaded from settings.json, then overridden by
/// LISTENER_* environment variables (see SettingsLoader). Missing keys keep these
/// defaults, so a settings file only needs the values you want to change.
public struct Settings: Sendable, Codable, Equatable {
    public var speech = SpeechSettings()
    public var turns = TurnSettings()
    public var answers = AnswerSettings()
    public var summary = SummarySettings()
    public var capture = CaptureSettings()
    public var storage = StorageSettings()
    public var hotkeys = HotkeySettings()
    public var window = WindowSettings()
    public var prices = PriceTable.standard

    public init() {}
}

public struct SpeechSettings: Sendable, Codable, Equatable {
    /// "google", or "fake" to replay a fixture's script without any network.
    public var provider = "google"
    public var googleProjectID: String?
    public var googleLocation = "eu"
    public var googleEndpoint = "eu-speech.googleapis.com"
    public var model = "chirp_3"
    public var languageCode = "en-GB"
    /// "standard", "short" or "supershort". Shorter finalises sooner but may cut
    /// slow speakers off mid-sentence.
    public var endpointingSensitivity = "short"
    /// Path to a Google credentials JSON. Nil means Application Default Credentials
    /// (~/.config/gcloud/application_default_credentials.json).
    public var googleCredentialsFile: String?
    /// Google closes streams after five minutes, so we move to a new one at the
    /// first pause after this many seconds.
    public var rotateAfterSeconds = 240.0
    /// Only send audio while the local VAD hears speech (plus a short pre-roll).
    /// Cuts speech-to-text cost; off until measured not to clip words.
    public var skipSilence = false

    public init() {}
}

public struct TurnSettings: Sendable, Codable, Equatable {
    /// A turn ends after this much silence, once its final text has arrived.
    public var silenceMs = 700
    /// Energy above this counts as speech for the local VAD.
    public var vadThresholdDBFS = -45.0
    /// Bursts of "speech" shorter than this are treated as noise (a click, a cough).
    public var minSpeechMs = 150

    public init() {}
}

public struct AnswerSettings: Sendable, Codable, Equatable {
    public var quick = ModelSettings(model: "claude-haiku-5-5", effort: "low", thinking: .off, maxTokens: 600)
    public var deep = ModelSettings(model: "claude-sonnet-5-5", effort: "medium", thinking: .adaptive, maxTokens: 4000)
    /// Transcript tokens sent with each answer. About ten minutes of conversation.
    public var transcriptBudgetTokens = 8_000
    /// Never send more than this, whatever the budget says. Haiku 5.5 prices rise
    /// fivefold above 100k prompt tokens.
    public var transcriptHardCapTokens = 60_000
    /// Who you are and what your calls are about. Goes into the system prompt.
    public var context = ""
    /// Start drafting an answer whenever "Them" finishes a turn, so the hotkey shows
    /// it instantly. Costs a fraction of a cent per turn on Haiku.
    public var draftAhead = false

    public init() {}

    public func settings(for tier: AnswerTier) -> ModelSettings {
        switch tier {
        case .quick: quick
        case .deep: deep
        }
    }
}

public struct SummarySettings: Sendable, Codable, Equatable {
    public var enabled = true
    public var model = ModelSettings(
        model: "claude-sonnet-5-5", effort: "medium", thinking: .adaptive, maxTokens: 8_000)

    public init() {}
}

public struct CaptureSettings: Sendable, Codable, Equatable {
    /// "tap" (Core Audio process tap) or "sck" (ScreenCaptureKit).
    public var systemAudioBackend = "tap"
    /// Apple echo cancellation on the mic. Only for calls on speakers.
    public var voiceProcessing = false

    public init() {}
}

public struct StorageSettings: Sendable, Codable, Equatable {
    /// Nil means ~/Library/Application Support/Listener/sessions.
    public var directory: String?
    public var retentionDays = 30
    /// Keep me.wav and them.wav with each session. Off: transcripts only.
    public var saveAudio = false

    public init() {}
}

public struct HotkeySettings: Sendable, Codable, Equatable {
    /// Modifier names: ctrl, option, shift, cmd. Key names: letters, digits, space,
    /// return, f1 to f12. Avoid option-only combinations, macOS 15 blocks them.
    public var quickAnswer = "ctrl+option+space"
    public var deepAnswer = "ctrl+option+shift+space"
    public var toggleListening = "ctrl+option+l"

    public init() {}
}

public struct WindowSettings: Sendable, Codable, Equatable {
    public var alwaysOnTop = true
    public var opacity = 0.97
    public var showDockIcon = false

    public init() {}
}
