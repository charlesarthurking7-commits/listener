import AVFoundation
import AppKit
import CoreGraphics
import ListenerCore

/// Reads permission state without ever prompting. Prompts only happen when the
/// user presses Start and capture begins.
enum SystemPermissions {
    static func microphone() -> ReadinessInput.Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// macOS only says whether access is granted, not whether it was refused, so
    /// anything else reads as "will ask".
    static func screenRecording() -> ReadinessInput.Permission {
        CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    @MainActor
    static func open(_ pane: PrivacyPane) {
        if let url = URL(string: pane.url) {
            NSWorkspace.shared.open(url)
        }
    }
}
