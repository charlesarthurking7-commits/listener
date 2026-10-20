import AppKit
import ListenerCore

/// Permission state for the setup checklist, read without ever prompting. Prompts
/// only happen when the user presses Start and capture begins.
enum SystemPermissions {
    static var microphone: ReadinessInput.Permission {
        permission(CapturePermissions.microphone)
    }

    /// macOS only says whether access is granted, not whether it was refused, so
    /// anything else reads as "will ask".
    static var screenRecording: ReadinessInput.Permission {
        CapturePermissions.screenRecordingGranted ? .granted : .notDetermined
    }

    @MainActor
    static func open(_ pane: PrivacyPane) {
        if let url = URL(string: pane.url) {
            NSWorkspace.shared.open(url)
        }
    }

    private static func permission(_ status: PermissionStatus) -> ReadinessInput.Permission {
        switch status {
        case .granted: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        }
    }
}
