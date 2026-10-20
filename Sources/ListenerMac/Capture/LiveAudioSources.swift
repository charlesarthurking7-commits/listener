import ListenerCore

/// The capture sources for a live call, as the settings ask for them.
public enum LiveAudioSources {
    /// - Parameter onEvent: hears about restarts and fallbacks the sources make on their
    ///   own, for logs or a warning in the UI. Called on the sources' private queues.
    public static func make(
        settings: CaptureSettings, onEvent: (@Sendable (CaptureEvent) -> Void)? = nil
    ) -> [Speaker: any AudioCaptureSource] {
        let systemAudio: any AudioCaptureSource
        switch settings.systemAudioBackend.lowercased() {
        case "sck":
            systemAudio = ScreenCaptureAudio(onEvent: onEvent)
        default:
            systemAudio = SystemAudioTap(onEvent: onEvent)
        }
        return [
            .me: MicrophoneCapture(voiceProcessing: settings.voiceProcessing, onEvent: onEvent),
            .them: systemAudio,
        ]
    }
}
