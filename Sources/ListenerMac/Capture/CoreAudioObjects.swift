import CoreAudio
import Foundation

let unknownAudioObject = AudioObjectID(kAudioObjectUnknown)

/// Small, typed wrappers around AudioObjectGetPropertyData so capture code reads
/// like what it does rather than like pointer bookkeeping.
enum CoreAudioObjects {
    static func defaultInputDevice() throws -> AudioDeviceID {
        try read(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
            default: unknownAudioObject)
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        try read(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
            default: unknownAudioObject)
    }

    static func deviceUID(_ device: AudioDeviceID) throws -> String {
        try readString(device, kAudioDevicePropertyDeviceUID)
    }

    static func name(_ object: AudioObjectID) -> String? {
        try? readString(object, kAudioObjectPropertyName)
    }

    /// The Core Audio object for a process, or nil if the process has never touched audio.
    static func processObject(pid: pid_t) throws -> AudioObjectID? {
        var address = globalAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = unknownAudioObject
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier,
            &size, &object
        )
        try check(status, "Translate PID to audio process")
        return object == unknownAudioObject ? nil : object
    }

    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        try read(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr {
            throw CaptureError.coreAudio(operation: operation, status: status)
        }
    }

    private static func read<Value>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default initial: Value
    ) throws -> Value {
        var address = globalAddress(selector)
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        try check(status, "Read audio property \(fourCharacterCode(Int32(bitPattern: selector)))")
        return value
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        try check(status, "Read audio property \(fourCharacterCode(Int32(bitPattern: selector)))")
        guard let value else {
            throw CaptureError.coreAudio(
                operation: "Read audio string property", status: OSStatus(kAudioHardwareUnspecifiedError))
        }
        return value.takeRetainedValue() as String
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
