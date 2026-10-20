import AVFoundation
import CoreAudio
import ListenerCore

/// The "Them" channel: a Core Audio process tap on everything the Mac plays except
/// this app. The tap is wrapped in a private aggregate device, because taps cannot
/// be read directly, only as an input of a device.
///
/// Needs the System Audio Recording permission. Without it macOS does not fail, it
/// delivers silence, which the spike reports.
///
/// Mutable state is only touched in start() and stop(), which the owner calls in
/// order from one task. The IO block only uses values captured at start.
public final class SystemAudioTap: AudioCaptureSource, @unchecked Sendable {
    private let queue = DispatchQueue(label: "listener.capture.tap", qos: .userInitiated)
    private var tapID = unknownAudioObject
    private var aggregateID = unknownAudioObject
    private var ioProcID: AudioDeviceIOProcID?

    public init() {}

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo {
        do {
            return try startTap(onChunk: onChunk)
        } catch {
            stop()
            throw error
        }
    }

    private func startTap(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws -> ChannelInfo {
        var excluded: [AudioObjectID] = []
        if let ownProcess = try CoreAudioObjects.processObject(pid: getpid()) {
            excluded.append(ownProcess)
        }
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        tapDescription.uuid = UUID()
        tapDescription.name = "Listener system audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        try CoreAudioObjects.check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "Create process tap")

        let outputDevice = try CoreAudioObjects.defaultOutputDevice()
        let outputUID = try CoreAudioObjects.deviceUID(outputDevice)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Listener system audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ]
            ],
        ]
        try CoreAudioObjects.check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
            "Create aggregate device"
        )

        var streamDescription = try CoreAudioObjects.tapFormat(tapID)
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CaptureError.unsupportedFormat("tap format with \(streamDescription.mChannelsPerFrame) channels")
        }
        let converter = try PCMConverter(inputFormat: format)
        let tapBuffers = TapBufferSelector(format: format)

        // With a dispatch queue, Core Audio calls the block on that queue instead of
        // the real-time IO thread, so converting here cannot cause audio glitches.
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, inputData, _, _, _ in
            let capturedAt = ContinuousClock.now
            guard let buffer = tapBuffers.buffer(from: inputData),
                let samples = try? converter.convert(buffer),
                !samples.isEmpty
            else {
                return
            }
            onChunk(AudioChunk(speaker: .them, samples: samples, capturedAt: capturedAt))
        }
        try CoreAudioObjects.check(status, "Create IO proc")
        try CoreAudioObjects.check(AudioDeviceStart(aggregateID, ioProcID), "Start aggregate device")

        let outputName = CoreAudioObjects.name(outputDevice) ?? "default output"
        return ChannelInfo(
            speaker: .them,
            backend: "Core Audio process tap",
            device: "all system audio, clocked by \(outputName)",
            nativeFormat: AudioFormatText.describe(format)
        )
    }

    public func stop() {
        if aggregateID != unknownAudioObject {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != unknownAudioObject {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = unknownAudioObject
        tapID = unknownAudioObject
    }
}

/// Picks the tap's audio out of the aggregate device's input.
///
/// The aggregate also contains the output device, and if that device has inputs of
/// its own (a headset mic, say) their buffers come first in the list, followed by the
/// tap's. Reading the whole list as tap audio would put your own voice on the "Them"
/// channel, so we take only the trailing buffers that belong to the tap.
///
/// Only used from the tap's serial queue, hence @unchecked Sendable.
private final class TapBufferSelector: @unchecked Sendable {
    private let format: AVAudioFormat
    private let tapBufferCount: Int
    private let list: UnsafeMutableAudioBufferListPointer

    init(format: AVAudioFormat) {
        self.format = format
        tapBufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        list = AudioBufferList.allocate(maximumBuffers: tapBufferCount)
    }

    deinit {
        free(list.unsafeMutablePointer)
    }

    func buffer(from inputData: UnsafePointer<AudioBufferList>) -> AVAudioPCMBuffer? {
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        if input.count < tapBufferCount {
            return nil
        }
        let firstTapBuffer = input.count - tapBufferCount
        for index in 0..<tapBufferCount {
            list[index] = input[firstTapBuffer + index]
        }
        return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer, deallocator: nil)
    }
}
