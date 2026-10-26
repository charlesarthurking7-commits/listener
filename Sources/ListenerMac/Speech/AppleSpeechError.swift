import Foundation
import Speech

/// Why on-device recognition could not start or had to stop, worded for the user.
enum AppleSpeechError: Error, CustomStringConvertible {
    case requiresMacOS26
    case unsupportedDevice
    case notInThisBuild
    case unsupportedLanguage(requested: String, supported: [String])
    case modelNotInstalled(language: String)
    case tooManyLanguages
    case busy
    case unsupportedAudioFormat(String)
    case failed(String)

    var description: String {
        switch self {
        case .requiresMacOS26:
            "On-device speech recognition needs macOS 26 or later. Use the Google provider on this Mac."
        case .unsupportedDevice:
            "This Mac cannot run Apple's on-device speech recognition. Use the Google provider instead."
        case .notInThisBuild:
            "This build of Listener was made without the macOS 26 SDK, so it has no on-device speech "
                + "recognition. Build it with Xcode 26 or later."
        case .unsupportedLanguage(let requested, let supported) where supported.isEmpty:
            "On-device speech recognition does not support \(requested)."
        case .unsupportedLanguage(let requested, let supported):
            "On-device speech recognition does not support \(requested). Supported: \(supported.joined(separator: ", "))."
        case .modelNotInstalled(let language):
            "The on-device speech model for \(language) is not installed yet. macOS keeps downloading it in the "
                + "background: check the internet connection and try again in a minute."
        case .tooManyLanguages:
            "macOS limits how many on-device speech languages an app may reserve, and Listener has reached it. "
                + "Use a language that is already installed."
        case .busy:
            "macOS would not start another on-device speech recognizer. Quit other apps that transcribe live "
                + "(Notes, Voice Memos, Live Captions) and try again."
        case .unsupportedAudioFormat(let format):
            "The on-device recognizer asked for audio as \(format), which Listener cannot convert to."
        case .failed(let reason):
            "On-device speech recognition failed: \(reason)"
        }
    }
}

#if compiler(>=6.2)
    @available(macOS 26.0, *)
    extension AppleSpeechError {
        /// Rewords the Speech framework errors a user can do something about.
        static func from(_ error: any Error, language: String) -> any Error {
            if error is AppleSpeechError || error is CancellationError {
                return error
            }
            let nsError = error as NSError
            guard nsError.domain == SFSpeechErrorDomain else {
                return AppleSpeechError.failed(nsError.localizedDescription)
            }
            switch nsError.code {
            case SFSpeechError.Code.insufficientResources.rawValue:
                return AppleSpeechError.busy
            case SFSpeechError.Code.tooManyAssetLocalesAllocated.rawValue:
                return AppleSpeechError.tooManyLanguages
            case SFSpeechError.Code.noModel.rawValue, SFSpeechError.Code.assetLocaleNotAllocated.rawValue:
                return AppleSpeechError.modelNotInstalled(language: language)
            default:
                return AppleSpeechError.failed(nsError.localizedDescription)
            }
        }
    }
#endif
