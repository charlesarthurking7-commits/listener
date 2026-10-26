import AVFoundation
import CoreGraphics
import ListenerCore

/// What macOS lets Listener capture. Reading a permission never prompts: prompts only
/// happen when the user presses Start and capture begins.
enum CapturePermissions {
    /// Microphone access for the "Me" channel.
    static var microphone: ReadinessInput.Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// Screen Recording access, needed only by the ScreenCaptureKit system audio backend.
    /// macOS only says whether access is granted, not whether it was refused, so anything
    /// else reads as "will ask".
    static var screenRecording: ReadinessInput.Permission {
        CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    /// Shows the macOS prompt if the user has not decided yet.
    static func requireMicrophone() async throws {
        let granted =
            switch microphone {
            case .granted: true
            case .denied: false
            case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
            }
        if !granted {
            throw CaptureError.microphonePermissionDenied
        }
    }

    /// macOS prompts only the first time; after that the user has to allow Listener in
    /// System Settings and reopen it.
    static func requireScreenRecording() throws {
        if !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess() {
            throw CaptureError.screenRecordingPermissionDenied
        }
    }
}
