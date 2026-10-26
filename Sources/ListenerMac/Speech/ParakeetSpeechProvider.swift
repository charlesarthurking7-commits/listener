import FluidAudio
import Foundation
import ListenerCore
import Synchronization

/// Parakeet Ultra, a post-trained NVIDIA Parakeet TDT 0.6B v3, on the Mac's Neural
/// Engine through FluidAudio. Free and on the Mac like Apple's recognizer, and on the
/// fixture channels read as dictations it made 30 word errors in 496 against Apple's 43.
///
/// It transcribes a stretch of audio at once rather than streaming, about 150 times
/// faster than real time, so a stream holds the dictation and transcribes it whole when
/// it finishes: a few hundred milliseconds even for a minute of speech.
///
/// The model (about 600 MB) downloads once from Hugging Face and loads in the
/// background. A stream asked for before it is ready fails at once, so dictation can
/// use another recognizer rather than wait.
public final class ParakeetSpeechProvider: SpeechToTextProvider {
    public let displayName = "Parakeet Ultra (on-device)"
    private let model: ParakeetModel

    public init(paths: ListenerPaths = .current) {
        model = ParakeetModel(
            directory: paths.supportDirectory.appendingPathComponent("Models/FluidAudio/parakeet-ultra"))
    }

    /// Downloads the model if needed and loads it, so the first dictation can use it.
    public func prepare() async throws {
        _ = try await model.manager()
    }

    public func openStream(for speaker: ListenerCore.Speaker) async throws -> any SpeechStream {
        guard let manager = await model.loadedManager() else {
            throw ParakeetError.notReady
        }
        return ParakeetStream(manager: manager)
    }
}

public enum ParakeetError: Error, CustomStringConvertible {
    case notReady

    public var description: String {
        switch self {
        case .notReady: "The Parakeet model is still loading."
        }
    }
}

/// Loads the model once, however many ask.
private actor ParakeetModel {
    private let directory: URL
    private var loading: Task<AsrManager, any Error>?
    private var loaded: AsrManager?

    init(directory: URL) {
        self.directory = directory
    }

    func manager() async throws -> AsrManager {
        if let loaded {
            return loaded
        }
        let task = loading ?? Task { [directory] in try await Self.load(from: directory) }
        loading = task
        do {
            let manager = try await task.value
            loaded = manager
            return manager
        } catch {
            // The next attempt starts afresh, for example once the Mac is back online.
            loading = nil
            throw error
        }
    }

    /// The model if it has loaded. Otherwise starts loading it and returns nil.
    func loadedManager() -> AsrManager? {
        if loaded == nil, loading == nil {
            Task { _ = try? await manager() }
        }
        return loaded
    }

    private static func load(from directory: URL) async throws -> AsrManager {
        let started = ContinuousClock.now
        let models = try await AsrModels.downloadAndLoad(to: directory, version: .ultra)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let seconds = (ContinuousClock.now - started).inSeconds
        Log.speech.notice("Parakeet Ultra ready after \(seconds, format: .fixed(precision: 1)) s")
        return manager
    }
}

/// Holds a dictation's audio and transcribes it whole when the stream finishes.
private final class ParakeetStream: SpeechStream, Sendable {
    let events: AsyncThrowingStream<SpeechEvent, any Error>
    private let output: AsyncThrowingStream<SpeechEvent, any Error>.Continuation
    private let manager: AsrManager
    private let samples = Mutex<[Float]>([])

    init(manager: AsrManager) {
        (events, output) = AsyncThrowingStream<SpeechEvent, any Error>.makeStream()
        self.manager = manager
    }

    func send(_ chunk: AudioChunk) async throws {
        samples.withLock { samples in
            samples.append(contentsOf: chunk.samples.lazy.map { Float($0) / 32768 })
        }
    }

    func finish() async {
        var audio = samples.withLock { $0 }
        guard !audio.isEmpty else {
            output.finish()
            return
        }
        // Parakeet refuses less than 0.3 s; silence makes up a short "Yes." to a second.
        if audio.count < AudioChunk.sampleRate {
            audio += [Float](repeating: 0, count: AudioChunk.sampleRate - audio.count)
        }
        do {
            var state = try TdtDecoderState(decoderLayers: AsrModelVersion.ultra.decoderLayers)
            let result = try await manager.transcribe(audio, decoderState: &state, language: .english)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                output.yield(
                    SpeechEvent(kind: .final, text: text, audioStart: 0, audioEnd: result.duration))
            }
            output.finish()
        } catch {
            output.finish(throwing: error)
        }
    }
}
