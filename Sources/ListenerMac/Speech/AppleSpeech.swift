import ListenerCore
import Speech

/// Entry points for Apple's on-device speech recognition. They live outside the macOS 26
/// types so the app, which runs on macOS 15, gets a clear error instead of a missing symbol.
///
/// No permission prompt is involved: SpeechAnalyzer runs on the Mac and needs no speech
/// recognition authorization. Only the one-off model download goes over the network,
/// handled by macOS.
public enum AppleSpeech {
    /// Whether this Mac can run on-device recognition at all, for showing the option.
    public static var isSupported: Bool {
        if #available(macOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    public static func makeProvider(
        settings: Settings, onModelState: @escaping @Sendable (OnDeviceSpeechStatus) -> Void
    ) throws -> any SpeechToTextProvider {
        guard #available(macOS 26.0, *) else {
            throw AppleSpeechError.requiresMacOS26
        }
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechError.unsupportedDevice
        }
        return AppleSpeechProvider(settings: settings, onModelState: onModelState)
    }

    /// Apple's recognizer as dictation uses it. Nobody reads its text until dictation
    /// stops, so it keeps one session throughout rather than ending one at every pause,
    /// and takes Apple's slower, more careful results. On the six fixture channels read
    /// as dictations that made 43 word errors in 496, against 50 with fast results and
    /// 68 ending a session at each pause, which also made up a "Yeah." at some of the
    /// cuts. Stopping waits about 0.2 s for the last words instead of 0.06 s.
    public static func makeDictationProvider(settings: Settings) throws -> any SpeechToTextProvider {
        guard #available(macOS 26.0, *) else {
            throw AppleSpeechError.requiresMacOS26
        }
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechError.unsupportedDevice
        }
        return AppleSpeechProvider(settings: settings, splitsAtPauses: false, fastResults: false) { _ in }
    }

    /// Checks the language and downloads its model if needed. Call it when the user picks
    /// this provider, so the first call does not sit waiting on a download.
    public static func installModel(
        languageCode: String, onState: @escaping @Sendable (OnDeviceSpeechStatus) -> Void
    ) async throws {
        guard #available(macOS 26.0, *) else {
            throw AppleSpeechError.requiresMacOS26
        }
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechError.unsupportedDevice
        }
        _ = try await ModelLoader.load(languageCode: languageCode, onState: onState)
    }
}
