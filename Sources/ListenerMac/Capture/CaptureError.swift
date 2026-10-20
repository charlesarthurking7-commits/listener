import ListenerCore

public enum CaptureError: Error, CustomStringConvertible {
    case microphonePermissionDenied
    case screenRecordingPermissionDenied
    case noInputDevice
    case noDisplay
    case unsupportedFormat(String)
    case conversionFailed
    case coreAudio(operation: String, status: Int32)

    public var description: String {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is denied. Allow it in System Settings > Privacy & Security > Microphone."
        case .screenRecordingPermissionDenied:
            "Screen Recording access is denied. Allow it in System Settings > Privacy & Security > Screen & System Audio Recording."
        case .noInputDevice:
            "No microphone found. In clamshell mode the built-in mics are off, so plug in a headset or USB mic."
        case .noDisplay:
            "ScreenCaptureKit returned no displays to attach the audio stream to."
        case .unsupportedFormat(let format):
            "Cannot convert audio format \(format) to 16 kHz mono."
        case .conversionFailed:
            "Audio conversion failed."
        case .coreAudio(let operation, let status):
            "\(operation) failed with OSStatus \(status) (\(fourCharacterCode(status)))."
        }
    }
}

/// Core Audio errors are usually four ASCII characters packed into an Int32, e.g. 'who?'.
func fourCharacterCode(_ status: Int32) -> String {
    let value = UInt32(bitPattern: status)
    var characters: [Character] = []
    for shift in [24, 16, 8, 0] {
        let byte = UInt8((value >> UInt32(shift)) & 0xFF)
        if byte < 32 || byte > 126 {
            return String(status)
        }
        characters.append(Character(UnicodeScalar(byte)))
    }
    return "'" + String(characters) + "'"
}
