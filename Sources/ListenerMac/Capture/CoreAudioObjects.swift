import CoreAudio
import Foundation

let unknownAudioObject = AudioObjectID(kAudioObjectUnknown)
let systemAudioObject = AudioObjectID(kAudioObjectSystemObject)

/// Small, typed wrappers around AudioObjectGetPropertyData so capture code reads
/// like what it does rather than like pointer bookkeeping.
enum CoreAudioObjects {
    /// The default input device, or nil when the Mac has none (a closed laptop with nothing plugged in).
    static func defaultInputDevice() throws -> AudioDeviceID? {
        let device: AudioDeviceID = try read(
            systemAudioObject, kAudioHardwarePropertyDefaultInputDevice, default: unknownAudioObject)
        return device == unknownAudioObject ? nil : device
    }

    /// The device apps play through, or nil when there is none.
    static func defaultOutputDevice() throws -> AudioDeviceID? {
        let device: AudioDeviceID = try read(
            systemAudioObject, kAudioHardwarePropertyDefaultOutputDevice, default: unknownAudioObject)
        return device == unknownAudioObject ? nil : device
    }

    static func deviceUID(_ device: AudioDeviceID) throws -> String {
        try readString(device, kAudioDevicePropertyDeviceUID)
    }

    static func name(_ object: AudioObjectID) -> String? {
        try? readString(object, kAudioObjectPropertyName)
    }

    static func nominalSampleRate(_ device: AudioDeviceID) throws -> Double {
        try read(device, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
    }

    /// The Core Audio object for a process, or nil if the process has never touched audio.
    static func processObject(pid: pid_t) throws -> AudioObjectID? {
        var address = globalAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = unknownAudioObject
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            systemAudioObject, &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier,
            &size, &object
        )
        try check(status, "Translate PID to audio process")
        return object == unknownAudioObject ? nil : object
    }

    /// Whether any process other than `excluded` is currently playing audio. Answers true
    /// when the process list cannot be read, so callers err on the side of acting.
    static func isAnotherProcessPlaying(excluding excluded: AudioObjectID?) -> Bool {
        guard let processes = try? processList() else {
            return true
        }
        for process in processes where process != excluded {
            let running: UInt32 = (try? read(process, kAudioProcessPropertyIsRunningOutput, default: 0)) ?? 0
            if running != 0 {
                return true
            }
        }
        return false
    }

    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        try read(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
    }

    /// The format IO procs receive for the device's last input stream (its "virtual format").
    static func lastInputStreamFormat(_ device: AudioDeviceID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "Read input stream list size")
        var streams = [AudioStreamID](
            repeating: unknownAudioObject, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams), "Read input stream list")
        guard let last = streams.prefix(Int(size) / MemoryLayout<AudioStreamID>.size).last else {
            throw CaptureError.coreAudio(
                operation: "Find input stream", status: OSStatus(kAudioHardwareBadStreamError))
        }
        return try read(last, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr {
            throw CaptureError.coreAudio(operation: operation, status: status)
        }
    }

    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func processList() throws -> [AudioObjectID] {
        var address = globalAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(systemAudioObject, &address, 0, nil, &size), "Read audio process list size")
        var processes = [AudioObjectID](
            repeating: unknownAudioObject, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(systemAudioObject, &address, 0, nil, &size, &processes),
            "Read audio process list")
        return Array(processes.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func read<Value>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default initial: Value
    ) throws -> Value {
        var address = globalAddress(selector)
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
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
}
