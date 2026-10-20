import AVFoundation
import ListenerCore

/// Puts our 16 kHz mono Int16 chunks into buffers of exactly the format the analyzer
/// asked for. SpeechAnalyzer never converts audio itself, and feeding it anything else
/// fails or crashes the process.
///
/// On macOS 26 the analyzer asks for 16 kHz mono Int16, so samples are copied straight
/// in. Any other format goes through one AVAudioConverter for the whole channel, so its
/// resampler state carries across chunks. Used from one actor only.
final class AnalyzerAudio {
    let format: AVAudioFormat
    private let converter: AVAudioConverter?

    init(analyzerFormat: AVAudioFormat) throws {
        format = analyzerFormat
        let matchesChunks =
            analyzerFormat.commonFormat == .pcmFormatInt16
            && analyzerFormat.sampleRate == Double(AudioChunk.sampleRate)
            && analyzerFormat.channelCount == 1
        if matchesChunks {
            converter = nil
            return
        }
        guard
            let chunkFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(AudioChunk.sampleRate),
                channels: 1,
                interleaved: true
            ),
            let converter = AVAudioConverter(from: chunkFormat, to: analyzerFormat)
        else {
            throw AppleSpeechError.unsupportedAudioFormat(AudioFormatText.describe(analyzerFormat))
        }
        self.converter = converter
    }

    /// Nil when there is nothing to send yet, e.g. an empty chunk.
    func buffer(for samples: [Int16]) throws -> AVAudioPCMBuffer? {
        guard let converter else {
            return Self.buffer(samples, format: format)
        }
        guard let input = Self.buffer(samples, format: converter.inputFormat) else {
            return nil
        }
        // Exactly the frames the input can fill: with spare room the converter asks for
        // more input, hears "no data now" and drops what it still had pending.
        let ratio = format.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        let pending = SingleBufferInput(input)
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
            throw conversionError ?? AppleSpeechError.failed("audio conversion failed")
        }
        return output.frameLength > 0 ? output : nil
    }

    private static func buffer(_ samples: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard
            !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.int16ChannelData?[0]
        else {
            return nil
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: source.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

/// Hands one buffer to AVAudioConverter's input block; see PendingInput in
/// PCMConverter.swift for why this is a class.
private final class SingleBufferInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
