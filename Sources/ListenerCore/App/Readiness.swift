import Foundation

/// Getting Apple's on-device speech model ready, as the app reports it.
public enum OnDeviceSpeechStatus: Sendable, Equatable {
    case checking
    /// macOS is downloading the model. Apple reports a fraction only, no sizes.
    case downloading(fractionCompleted: Double)
    /// The BCP 47 code actually in use, which can be a near match of the one asked for,
    /// e.g. another region of the same language.
    case ready(locale: String)
    /// Not available on this Mac, or the model could not be loaded.
    case failed(String)
}

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
    /// The tap has delivered speech on an earlier call, which it only does once System
    /// Audio Recording is allowed.
    public var systemAudioHeard: Bool
    public var speechProvider: String
    /// The Google Cloud project that will be billed: speech.googleProjectID, or the
    /// quota project in the credentials file.
    public var googleProjectID: String?
    /// Why Google credentials could not be loaded, or nil if they were found.
    public var googleCredentialsProblem: String?
    /// For the "apple" provider; nil until the model has been checked.
    public var onDeviceSpeech: OnDeviceSpeechStatus?
    public var hasAnthropicKey: Bool

    public init(
        microphone: Permission,
        screenRecording: Permission? = nil,
        systemAudioHeard: Bool = false,
        speechProvider: String,
        googleProjectID: String? = nil,
        googleCredentialsProblem: String? = nil,
        onDeviceSpeech: OnDeviceSpeechStatus? = nil,
        hasAnthropicKey: Bool
    ) {
        self.microphone = microphone
        self.screenRecording = screenRecording
        self.systemAudioHeard = systemAudioHeard
        self.speechProvider = speechProvider
        self.googleProjectID = googleProjectID
        self.googleCredentialsProblem = googleCredentialsProblem
        self.onDeviceSpeech = onDeviceSpeech
        self.hasAnthropicKey = hasAnthropicKey
    }
}

/// A System Settings pane that can be opened directly.
public enum PrivacyPane: String, Sendable {
    case microphone = "Privacy_Microphone"
    case screenAndSystemAudioRecording = "Privacy_ScreenCapture"
    case accessibility = "Privacy_Accessibility"

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
        /// Being set up in the background, e.g. a model download.
        case preparing
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
    /// A few words for the compact list once everything is set up, e.g. "Allowed".
    public let summary: String
}

/// How far the setup checklist is: items that need nothing more from the user, out of all.
public struct ReadinessProgress: Sendable, Equatable {
    public let done: Int
    public let total: Int

    public var isComplete: Bool { done == total }
}

public enum Readiness {
    public static func check(_ input: ReadinessInput) -> [ReadinessItem] {
        [
            microphone(input.microphone), systemAudio(input.screenRecording, heard: input.systemAudioHeard),
            speech(input), answers(input),
        ]
    }

    public static func blocksStart(_ items: [ReadinessItem]) -> Bool {
        items.contains { $0.status == .blocking }
    }

    /// "Will ask" counts as done: macOS asks on the first Start and there is nothing to do
    /// before then.
    public static func progress(_ items: [ReadinessItem]) -> ReadinessProgress {
        ReadinessProgress(done: items.filter { $0.status == .ready || $0.status == .willAsk }.count, total: items.count)
    }

    /// The full checklist shows until nothing blocks a call and nothing is limited;
    /// after that a compact summary is enough.
    public static func needsAttention(_ items: [ReadinessItem]) -> Bool {
        items.contains { $0.status == .blocking || $0.status == .limited }
    }

    private static func microphone(_ permission: ReadinessInput.Permission) -> ReadinessItem {
        switch permission {
        case .granted:
            ReadinessItem(
                id: "microphone", title: "Microphone", detail: "Allowed. Your voice is the \"Me\" channel.",
                status: .ready, fix: nil, summary: "Allowed")
        case .notDetermined:
            ReadinessItem(
                id: "microphone", title: "Microphone",
                detail: "macOS will ask for access when you press Start. Choose Allow.",
                status: .willAsk, fix: nil, summary: "macOS asks on Start")
        case .denied:
            ReadinessItem(
                id: "microphone", title: "Microphone",
                detail: "Access is off. Turn on Listener in Privacy & Security > Microphone, then press Start again.",
                status: .blocking, fix: .openPrivacySettings(.microphone), summary: "Turned off")
        }
    }

    private static func systemAudio(_ screenRecording: ReadinessInput.Permission?, heard: Bool) -> ReadinessItem {
        switch screenRecording {
        case nil where heard:
            ReadinessItem(
                id: "systemAudio", title: "System audio", detail: "Allowed. The Mac's audio is the \"Them\" channel.",
                status: .ready, fix: nil, summary: "Allowed")
        case nil:
            ReadinessItem(
                id: "systemAudio", title: "System audio",
                detail:
                    "macOS asks for System Audio Recording the first time. If \"Them\" stays silent, turn on Listener "
                    + "under Screen & System Audio Recording.",
                status: .willAsk, fix: .openPrivacySettings(.screenAndSystemAudioRecording),
                summary: "macOS asks on Start")
        case .granted:
            ReadinessItem(
                id: "systemAudio", title: "System audio", detail: "Screen Recording is allowed.",
                status: .ready, fix: nil, summary: "Allowed")
        case .notDetermined, .denied:
            ReadinessItem(
                id: "systemAudio", title: "System audio",
                detail:
                    "The ScreenCaptureKit backend needs Screen Recording. macOS asks when you press Start; if you "
                    + "denied it before, turn on Listener under Screen & System Audio Recording.",
                status: .willAsk, fix: .openPrivacySettings(.screenAndSystemAudioRecording),
                summary: "macOS asks on Start")
        }
    }

    private static func speech(_ input: ReadinessInput) -> ReadinessItem {
        switch input.speechProvider {
        case "apple":
            onDeviceSpeech(input.onDeviceSpeech)
        case "fake":
            item(
                .blocking, "speech.provider is \"fake\", which only works with listener replay --script.",
                fix: .editSettings, summary: "Needs setting up")
        default:
            googleSpeech(input)
        }
    }

    private static func googleSpeech(_ input: ReadinessInput) -> ReadinessItem {
        if let problem = input.googleCredentialsProblem {
            return item(
                .blocking, "Google credentials: \(problem)",
                fix: .runInTerminal("gcloud auth application-default login"), summary: "Needs signing in")
        }
        guard let project = input.googleProjectID, !project.trimmingCharacters(in: .whitespaces).isEmpty else {
            return item(
                .blocking, "Set speech.googleProjectID in settings.json to your Google Cloud project.",
                fix: .editSettings, summary: "Needs a project")
        }
        return item(.ready, "Google Cloud, project \(project).", summary: "Google Cloud")
    }

    private static func onDeviceSpeech(_ status: OnDeviceSpeechStatus?) -> ReadinessItem {
        switch status {
        case nil, .checking:
            item(.preparing, "Checking Apple's on-device speech model.", summary: "Checking")
        case .downloading(let fraction):
            item(
                .preparing,
                "macOS is downloading the on-device speech model (\(percent(fraction))). "
                    + "Wait for it to finish before starting a call.",
                summary: "Downloading \(percent(fraction))")
        case .ready(let locale):
            item(
                .ready, "On this Mac (\(locale)). Call audio is not sent anywhere for transcription.",
                summary: "On this Mac")
        case .failed(let message):
            item(.blocking, message, fix: .editSettings, summary: "Unavailable")
        }
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private static func item(
        _ status: ReadinessItem.Status, _ detail: String, fix: ReadinessFix? = nil, summary: String
    ) -> ReadinessItem {
        ReadinessItem(id: "speech", title: "Speech to text", detail: detail, status: status, fix: fix, summary: summary)
    }

    private static func answers(_ input: ReadinessInput) -> ReadinessItem {
        if input.hasAnthropicKey {
            return ReadinessItem(
                id: "answers", title: "Answers and summary", detail: "Anthropic API key found.",
                status: .ready, fix: nil, summary: "Key found")
        }
        return ReadinessItem(
            id: "answers", title: "Answers and summary",
            detail: "No Anthropic API key, so the transcript works but answers and the summary are off.",
            status: .limited, fix: .runInTerminal("listener secrets set anthropic"), summary: "No API key")
    }
}
