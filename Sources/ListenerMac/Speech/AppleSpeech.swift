import ListenerCore
import Speech

// SpeechAnalyzer first shipped in the macOS 26 SDK, which comes with Xcode 26 and Swift
// 6.2. Builds with Xcode 16 leave the on-device provider out rather than fail to compile.

/// Entry points for Apple's on-device speech recognition. They live outside the macOS 26
/// types so the app, which runs on macOS 15, gets a clear error instead of a missing symbol.
///
/// No permission prompt is involved: SpeechAnalyzer runs on the Mac and needs no speech
/// recognition authorization. Only the one-off model download goes over the network,
/// handled by macOS.
public enum AppleSpeech {
    /// Whether this Mac can run on-device recognition at all, for showing the option.
    public static var isSupported: Bool {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                return SpeechTranscriber.isAvailable
            }
        #endif
        return false
    }

    public static func makeProvider(
        settings: Settings,
        onModelState: @escaping @Sendable (AppleSpeechModelState) -> Void = { _ in }
    ) throws -> any SpeechToTextProvider {
        #if compiler(>=6.2)
            guard #available(macOS 26.0, *) else {
                throw AppleSpeechError.requiresMacOS26
            }
            guard SpeechTranscriber.isAvailable else {
                throw AppleSpeechError.unsupportedDevice
            }
            return AppleSpeechProvider(settings: settings, onModelState: onModelState)
        #else
            throw AppleSpeechError.notInThisBuild
        #endif
    }

    /// Checks the language and downloads its model if needed. Call it when the user picks
    /// this provider, so the first call does not sit waiting on a download.
    public static func installModel(
        languageCode: String,
        onState: @escaping @Sendable (AppleSpeechModelState) -> Void = { _ in }
    ) async throws {
        #if compiler(>=6.2)
            guard #available(macOS 26.0, *) else {
                throw AppleSpeechError.requiresMacOS26
            }
            guard SpeechTranscriber.isAvailable else {
                throw AppleSpeechError.unsupportedDevice
            }
            _ = try await ModelLoader.load(languageCode: languageCode, onState: onState)
        #else
            throw AppleSpeechError.notInThisBuild
        #endif
    }
}

/// Getting the on-device model ready, for the UI to show.
public enum AppleSpeechModelState: Sendable, Equatable {
    case checking
    /// macOS is downloading the model. Apple reports a fraction only, no sizes.
    case downloading(fractionCompleted: Double)
    /// The BCP 47 code in use. It can differ from the one asked for when macOS only has a
    /// near match, e.g. another region of the same language.
    case ready(locale: String)
}
