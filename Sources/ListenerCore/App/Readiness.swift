import Foundation

/// What the app found out about the Mac and the configuration before a call. The
/// macOS layer fills this in; `Readiness.check` decides what to tell the user.
public struct ReadinessInput: Sendable, Equatable {
    public enum Permission: Sendable, Equatable {
        case granted
        /// macOS has not asked yet. It asks when capture starts.
        case notDetermined
        case denied
    }

    public var microphone: Permission
    /// Only checked for the ScreenCaptureKit backend; nil for the Core Audio tap,
    /// whose permission macOS does not let apps query.
    public var screenRecording: Permission?
    public var speechProvider: String
    public var googleProjectID: String?
    /// Why Google credentials could not be loaded, or nil if they were found.
    public var googleCredentialsProblem: String?
    public var hasAnthropicKey: Bool

    public init(
        microphone: Permission,
        screenRecording: Permission? = nil,
        speechProvider: String,
        googleProjectID: String?,
        googleCredentialsProblem: String?,
        hasAnthropicKey: Bool
    ) {
        self.microphone = microphone
        self.screenRecording = screenRecording
        self.speechProvider = speechProvider
        self.googleProjectID = googleProjectID
        self.googleCredentialsProblem = googleCredentialsProblem
        self.hasAnthropicKey = hasAnthropicKey
    }
}

/// A System Settings pane that can be opened directly.
public enum PrivacyPane: String, Sendable {
    case microphone = "Privacy_Microphone"
    case screenAndSystemAudioRecording = "Privacy_ScreenCapture"

    public var url: String {
        "x-apple.systempreferences:com.apple.preference.security?\(rawValue)"
    }
}

public enum ReadinessFix: Sendable, Equatable {
    case openPrivacySettings(PrivacyPane)
    case editSettings
    case runInTerminal(String)
}

public struct ReadinessItem: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case ready
        /// Fine for now: macOS will ask when the call starts.
        case willAsk
        /// Works, but something is off, e.g. answers are disabled.
        case limited
        /// Listening cannot start until this is fixed.
        case blocking
    }

    public let id: String
    public let title: String
    public let detail: String
    public let status: Status
    public let fix: ReadinessFix?
}

public enum Readiness {
    public static func check(_ input: ReadinessInput) -> [ReadinessItem] {
        [microphone(input.microphone), systemAudio(input.screenRecording), speech(input), answers(input)]
    }

    public static func blocksStart(_ items: [ReadinessItem]) -> Bool {
        items.contains { $0.status == .blocking }
    }

    private static func microphone(_ permission: ReadinessInput.Permission) -> ReadinessItem {
        switch permission {
        case .granted:
            ReadinessItem(
                id: "microphone", title: "Microphone", detail: "Allowed. Your voice is the \"Me\" channel.",
                status: .ready, fix: nil)
        case .notDetermined:
            ReadinessItem(
                id: "microphone", title: "Microphone",
                detail: "macOS will ask for access when you press Start. Choose Allow.",
                status: .willAsk, fix: nil)
        case .denied:
            ReadinessItem(
                id: "microphone", title: "Microphone",
                detail: "Access is off. Turn on Listener in Privacy & Security > Microphone, then press Start again.",
                status: .blocking, fix: .openPrivacySettings(.microphone))
        }
    }

    private static func systemAudio(_ screenRecording: ReadinessInput.Permission?) -> ReadinessItem {
        switch screenRecording {
        case nil:
            ReadinessItem(
                id: "systemAudio", title: "System audio",
                detail:
                    "macOS asks for System Audio Recording the first time. If \"Them\" stays silent, turn on Listener "
                    + "under Screen & System Audio Recording.",
                status: .willAsk, fix: .openPrivacySettings(.screenAndSystemAudioRecording))
        case .granted:
            ReadinessItem(
                id: "systemAudio", title: "System audio", detail: "Screen Recording is allowed.",
                status: .ready, fix: nil)
        case .notDetermined, .denied:
            ReadinessItem(
                id: "systemAudio", title: "System audio",
                detail:
                    "The ScreenCaptureKit backend needs Screen Recording. macOS asks when you press Start; if you "
                    + "denied it before, turn on Listener under Screen & System Audio Recording.",
                status: .willAsk, fix: .openPrivacySettings(.screenAndSystemAudioRecording))
        }
    }

    private static func speech(_ input: ReadinessInput) -> ReadinessItem {
        if input.speechProvider == "fake" {
            return ReadinessItem(
                id: "speech", title: "Speech to text",
                detail: "speech.provider is \"fake\", which only works with listener replay --script.",
                status: .blocking, fix: .editSettings)
        }
        guard let project = input.googleProjectID, !project.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ReadinessItem(
                id: "speech", title: "Speech to text",
                detail: "Set speech.googleProjectID in settings.json to your Google Cloud project.",
                status: .blocking, fix: .editSettings)
        }
        if let problem = input.googleCredentialsProblem {
            return ReadinessItem(
                id: "speech", title: "Speech to text", detail: "Google credentials: \(problem)",
                status: .blocking, fix: .runInTerminal("gcloud auth application-default login"))
        }
        return ReadinessItem(
            id: "speech", title: "Speech to text", detail: "Google Cloud project \(project).",
            status: .ready, fix: nil)
    }

    private static func answers(_ input: ReadinessInput) -> ReadinessItem {
        if input.hasAnthropicKey {
            return ReadinessItem(
                id: "answers", title: "Answers and summary", detail: "Anthropic API key found.",
                status: .ready, fix: nil)
        }
        return ReadinessItem(
            id: "answers", title: "Answers and summary",
            detail: "No Anthropic API key, so the transcript works but answers and the summary are off.",
            status: .limited, fix: .runInTerminal("listener secrets set anthropic"))
    }
}
