import AVFoundation
import ListenerCore

/// Converts whatever a capture device delivers (usually 48 kHz float, one or two
/// channels) into the 16 kHz mono Int16 that speech-to-text expects.
///
/// AVAudioConverter keeps filter state between calls, so one instance must only be
/// fed from one capture thread. That is the reason for @unchecked Sendable.
final class PCMConverter: @unchecked Sendable {
    let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    /// - Parameter mixAllChannels: average all input channels. When false only the
    ///   first channel is kept, which is what voice processing needs because it puts
    ///   the cleaned-up signal on channel 0 and reference signals on the others (it
    ///   can turn a one-channel mic into three or more).
    init(inputFormat: AVAudioFormat, mixAllChannels: Bool = true) throws {
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(AudioChunk.sampleRate),
                channels: 1,
                interleaved: true
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw CaptureError.unsupportedFormat(AudioFormatText.describe(inputFormat))
        }
        converter.downmix = mixAllChannels
        if !mixAllChannels {
            converter.channelMap = [0]
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Int16] {
        if buffer.frameLength == 0 {
            return []
        }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }

        // The converter pulls input through this block. Handing it the buffer once and
        // then saying "no data now" keeps its resampler state for the next call.
        let pending = PendingInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let next = pending.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }
        if status == .error {
            throw conversionError ?? CaptureError.conversionFailed
        }

        guard let channel = output.int16ChannelData?[0] else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// Hands one buffer to AVAudioConverter's input block. A class rather than a captured
/// `var` so it compiles whether or not the SDK marks that block @Sendable; the block
/// runs synchronously inside convert(), so there is no real concurrent access.
private final class PendingInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

enum AudioFormatText {
    static func describe(_ format: AVAudioFormat) -> String {
        let kHz = format.sampleRate / 1000
        let rate = kHz == kHz.rounded() ? String(format: "%.0f", kHz) : String(format: "%.1f", kHz)
        let sampleType: String
        switch format.commonFormat {
        case .pcmFormatFloat32: sampleType = "float32"
        case .pcmFormatFloat64: sampleType = "float64"
        case .pcmFormatInt16: sampleType = "int16"
        case .pcmFormatInt32: sampleType = "int32"
        default: sampleType = "other"
        }
        let layout = format.isInterleaved ? "interleaved" : "planar"
        return "\(rate) kHz, \(format.channelCount) ch, \(sampleType) \(layout)"
    }
}
