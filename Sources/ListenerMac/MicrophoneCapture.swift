import AVFoundation
import ListenerCore

/// The "Me" channel: the default input device through AVAudioEngine.
///
/// Mutable state is only touched in start() and stop(), which the owner calls in
/// order from one task, hence @unchecked Sendable.
public final class MicrophoneCapture: AudioCaptureSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let voiceProcessing: Bool
    private var running = false

    /// - Parameter voiceProcessing: turn on Apple's echo cancellation. Only useful
    ///   when the call plays through speakers instead of headphones.
    public init(voiceProcessing: Bool) {
        self.voiceProcessing = voiceProcessing
    }

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo {
        try await Self.requestPermission()

        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Voice processing ducks all other audio by default, which would turn the
            // call down. Minimum is the lowest setting macOS offers; there is no "off".
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        let converter = try PCMConverter(inputFormat: format, mixAllChannels: !voiceProcessing)
        // Ask for 100 ms buffers. macOS treats this as a hint, the spike measures what we really get.
        let bufferSize = AVAudioFrameCount(format.sampleRate / 10)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            let capturedAt = ContinuousClock.now
            guard let samples = try? converter.convert(buffer), !samples.isEmpty else {
                return
            }
            onChunk(AudioChunk(speaker: .me, samples: samples, capturedAt: capturedAt))
        }

        engine.prepare()
        try engine.start()
        running = true

        var device = "unknown"
        if let id = try? CoreAudioObjects.defaultInputDevice(), let name = CoreAudioObjects.name(id) {
            device = name
        }
        return ChannelInfo(
            speaker: .me,
            backend: voiceProcessing ? "AVAudioEngine with voice processing" : "AVAudioEngine",
            device: device,
            nativeFormat: AudioFormatText.describe(format)
        )
    }

    public func stop() {
        if !running {
            return
        }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    static func requestPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) {
                return
            }
            throw CaptureError.microphonePermissionDenied
        default:
            throw CaptureError.microphonePermissionDenied
        }
    }
}
