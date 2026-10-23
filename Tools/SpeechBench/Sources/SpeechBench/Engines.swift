import AVFoundation
import FluidAudio
import Foundation
import Speech
import WhisperKit

/// A speech-to-text model that transcribes one segment at a time, the way a live call
/// would hand it each stretch of speech once the speaker pauses.
protocol SpeechEngine: AnyObject {
    var name: String { get }
    /// Downloads the model the first time, then loads it.
    func prepare() async throws
    /// 16 kHz mono samples, -1...1.
    func transcribe(_ samples: [Float]) async throws -> String
}

struct BenchError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

enum Engines {
    static let defaults = ["apple-en-GB", "apple-en-US", "whisper-turbo", "parakeet-v2", "parakeet-ultra"]

    static let help = """
        apple-<locale>    Apple on-device, what Listener uses today (e.g. apple-en-GB, apple-en-IN)
        whisper-turbo     Whisper large-v3 turbo (WhisperKit, about 1.6 GB)
        whisper-large-v3  Whisper large-v3, the full model (WhisperKit, about 3 GB, slower)
        parakeet-v2       NVIDIA Parakeet TDT 0.6B v2, English only (FluidAudio, about 0.5 GB)
        parakeet-v3       NVIDIA Parakeet TDT 0.6B v3, 25 languages (FluidAudio, about 0.5 GB)
        parakeet-ultra    Parakeet Ultra, a post-trained v3 (FluidAudio, about 0.6 GB)
        """

    /// Where the open models are kept, so they are easy to find and delete.
    static let modelsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Listener/Models", isDirectory: true)

    static func make(_ name: String) throws -> any SpeechEngine {
        if name.hasPrefix("apple-") {
            return AppleEngine(name: name, languageCode: String(name.dropFirst("apple-".count)))
        }
        switch name {
        case "whisper-turbo":
            return WhisperEngine(name: name, variant: "large-v3-v20240930_turbo")
        case "whisper-large-v3":
            return WhisperEngine(name: name, variant: "large-v3")
        case "parakeet-v2":
            return ParakeetEngine(name: name, version: .v2)
        case "parakeet-v3":
            return ParakeetEngine(name: name, version: .v3)
        case "parakeet-ultra":
            return ParakeetEngine(name: name, version: .ultra)
        default:
            throw BenchError("Unknown engine \"\(name)\". The engines are:\n\(help)")
        }
    }
}

/// Apple's SpeechTranscriber with a fresh analyzer per segment, since a module may only
/// ever join one analyzer.
final class AppleEngine: SpeechEngine {
    let name: String
    private let languageCode: String
    private var locale = Locale.current
    private var format: AVAudioFormat?

    init(name: String, languageCode: String) {
        self.name = name
        self.languageCode = languageCode
    }

    func prepare() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw BenchError("This Mac can't run Apple's on-device transcriber.")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: languageCode))
        else {
            throw BenchError("Apple's on-device transcriber has no \(languageCode) model.")
        }
        self.locale = locale
        let transcriber = makeTranscriber()
        try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        if format == nil {
            throw BenchError("The \(languageCode) model did not install.")
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let format else {
            throw BenchError("\(name) was not prepared.")
        }
        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        let collected = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        let (inputs, input) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)
        input.yield(AnalyzerInput(buffer: try Self.buffer(samples, format: format)))
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collected.value
    }

    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }

    /// The samples in exactly the format the analyzer asked for; it never converts audio itself.
    private static func buffer(_ samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
            let converter = AVAudioConverter(from: source, to: format)
        else {
            throw BenchError("Can't convert audio for the analyzer (\(format)).")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        if let channel = input.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    channel.update(from: base, count: source.count)
                }
            }
        }

        let capacity = AVAudioFrameCount((Double(samples.count) * format.sampleRate / 16_000).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw BenchError("Can't allocate an analyzer buffer.")
        }
        let pending = PendingBuffer(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let next = pending.take() else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }
        if status == .error {
            throw conversionError ?? BenchError("Audio conversion failed.")
        }
        return output
    }
}

/// Hands one buffer to AVAudioConverter's input block, which may be called more than once.
private final class PendingBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

final class WhisperEngine: SpeechEngine {
    let name: String
    private let variant: String
    private var pipe: WhisperKit?

    init(name: String, variant: String) {
        self.name = name
        self.variant = variant
    }

    func prepare() async throws {
        let config = WhisperKitConfig(
            model: variant,
            downloadBase: Engines.modelsDirectory.appendingPathComponent("WhisperKit", isDirectory: true),
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true
        )
        pipe = try await WhisperKit(config)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let pipe else {
            throw BenchError("\(name) was not prepared.")
        }
        // English, so a few words of another language are not taken as a language switch.
        let options = DecodingOptions(
            language: "en",
            temperature: 0,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        // Whisper marks stretches it heard no words in, e.g. [BLANK_AUDIO].
        return results.map(\.text).joined(separator: " ")
            .replacing(/\[[^\]]*\]/, with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

final class ParakeetEngine: SpeechEngine {
    let name: String
    private let version: AsrModelVersion
    private let manager = AsrManager(config: .default)

    init(name: String, version: AsrModelVersion) {
        self.name = name
        self.version = version
    }

    func prepare() async throws {
        let directory = Engines.modelsDirectory.appendingPathComponent("FluidAudio/\(name)", isDirectory: true)
        let models = try await AsrModels.downloadAndLoad(to: directory, version: version)
        try await manager.loadModels(models)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        // Each segment starts afresh, as each would live.
        var state = try TdtDecoderState(decoderLayers: version.decoderLayers)
        let language: Language? = version == .v2 ? nil : .english
        return try await manager.transcribe(samples, decoderState: &state, language: language).text
    }
}
