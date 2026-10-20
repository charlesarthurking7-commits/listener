import AVFoundation
import CoreGraphics

public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
}

/// What macOS lets Listener capture, and how to ask for it.
public enum CapturePermissions {
    /// Microphone access for the "Me" channel.
    public static var microphone: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// Shows the macOS prompt if the user has not decided yet. Returns whether access is granted.
    public static func requestMicrophone() async -> Bool {
        switch microphone {
        case .granted: true
        case .denied: false
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    /// Screen Recording access, needed only by the ScreenCaptureKit system audio backend.
    /// Checking never shows a prompt.
    public static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks for Screen Recording access. macOS prompts only the first time; after that
    /// the user has to allow Listener in System Settings and reopen it.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// The Core Audio tap backend needs System Audio Recording access, which macOS
    /// neither reports nor lets an app ask for up front.
    public static let systemAudioExplanation = """
        macOS asks for System Audio Recording access the first time Listener captures the \
        other side of a call, and offers no way to check it afterwards. Without it the "Them" \
        channel is pure digital silence, so Listener watches for that: if "Them" stays silent \
        while audio is playing, allow Listener in System Settings > Privacy & Security > \
        Screen & System Audio Recording, under "System Audio Recording Only".
        """

    static func requireMicrophone() async throws {
        if !(await requestMicrophone()) {
            throw CaptureError.microphonePermissionDenied
        }
    }

    static func requireScreenRecording() throws {
        if !screenRecordingGranted && !requestScreenRecording() {
            throw CaptureError.screenRecordingPermissionDenied
        }
    }
}
