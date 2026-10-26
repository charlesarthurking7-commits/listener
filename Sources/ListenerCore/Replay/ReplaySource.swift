import Foundation
import Synchronization

public enum ReplayError: Error, Equatable {
    case unsupportedRate(Int)
    case invalidSpeed(Double)
    case alreadyStarted
}

/// Plays a WAV file as if it were live capture: 16 kHz mono chunks of 100 ms, delivered
/// at the pace they would have been recorded (or faster with `speed`). Replay and tests
/// feed the whole pipeline through this, so it behaves exactly as it does on a call.
///
/// The file must be 16 kHz, as every recording Listener writes is; more than one
/// channel is mixed to mono. Convert anything else first, for example with
/// `afconvert -f WAVE -d LEI16@16000 -c 1 in.wav out.wav`.
///
/// Each chunk's `capturedAt` is when its last sample would have been captured at the
/// chosen pace. Unpaced, chunks arrive as fast as they can be taken, still stamped at
/// real-time pace; transcript times then match the file, but latency numbers mean
/// nothing.
public final class ReplaySource: AudioCaptureSource, Sendable {
    public enum Pacing: Sendable, Equatable {
        /// `speed` 1 is real time, 4 plays a minute of audio in 15 seconds.
        case realTime(speed: Double)
        case unpaced

        public static let realTime = Pacing.realTime(speed: 1)
    }

    public let speaker: Speaker
    public let audio: WAVAudio
    public let pacing: Pacing
    public let name: String

    private let playback = Mutex<Task<Void, Never>?>(nil)

    public init(
        audio: WAVAudio, speaker: Speaker, pacing: Pacing = .realTime, name: String = "in-memory audio"
    ) throws {
        guard audio.sampleRate == AudioChunk.sampleRate else {
            throw ReplayError.unsupportedRate(audio.sampleRate)
        }
        if case .realTime(let speed) = pacing, !(speed > 0 && speed.isFinite) {
            throw ReplayError.invalidSpeed(speed)
        }
        self.audio = audio
        self.speaker = speaker
        self.pacing = pacing
        self.name = name
    }

    public convenience init(url: URL, speaker: Speaker, speed: Double) throws {
        try self.init(
            audio: WAVReader.read(url: url), speaker: speaker, pacing: .realTime(speed: speed),
            name: url.lastPathComponent)
    }

    /// Seconds of audio in the file.
    public var duration: Double { Double(audio.frameCount) / Double(audio.sampleRate) }

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo {
        let (samples, speaker, pacing) = (monoSamples(), speaker, pacing)

        try playback.withLock { playback in
            guard playback == nil else {
                throw ReplayError.alreadyStarted
            }
            // Taken now rather than when the task first runs, so two sources started one
            // after the other stay in step even on a busy machine.
            let origin = ContinuousClock.now
            playback = Task {
                await Self.play(samples, speaker: speaker, pacing: pacing, origin: origin, onChunk: onChunk)
            }
        }
        return ChannelInfo(speaker: speaker, backend: "replay", device: name, nativeFormat: formatDescription)
    }

    /// Stops delivering chunks. The chunk being delivered, if any, still arrives.
    public func stop() {
        playback.withLock { $0?.cancel() }
    }

    /// Returns once the whole file has been delivered, or playback was stopped. Returns
    /// at once if playback never started.
    public func waitUntilFinished() async {
        let task = playback.withLock { $0 }
        await task?.value
    }

    private static func play(
        _ samples: [Int16], speaker: Speaker, pacing: Pacing, origin: ContinuousClock.Instant,
        onChunk: @Sendable (AudioChunk) -> Void
    ) async {
        // Exact 100 ms chunks, as a capture device would deliver them; the last may be short.
        let chunkLength = AudioChunk.sampleRate / 10
        for start in stride(from: 0, to: samples.count, by: chunkLength) {
            let end = min(start + chunkLength, samples.count)
            let audioTime = Duration.seconds(Double(end) / Double(AudioChunk.sampleRate))
            let capturedAt: ContinuousClock.Instant
            switch pacing {
            case .realTime(let speed):
                capturedAt = origin + audioTime / speed
                guard (try? await Task.sleep(until: capturedAt, clock: .continuous)) != nil else {
                    return
                }
            case .unpaced:
                capturedAt = origin + audioTime
                await Task.yield()
                if Task.isCancelled {
                    return
                }
            }
            onChunk(AudioChunk(speaker: speaker, samples: Array(samples[start..<end]), capturedAt: capturedAt))
        }
    }

    /// The average of every channel in the file.
    private func monoSamples() -> [Int16] {
        let channelCount = audio.channelCount
        guard channelCount > 1 else {
            return audio.samples
        }
        return (0..<audio.frameCount).map { frame in
            let first = frame * channelCount
            let sum = audio.samples[first..<first + channelCount].reduce(0) { $0 + Int($1) }
            return Int16((Double(sum) / Double(channelCount)).rounded())
        }
    }

    private var formatDescription: String {
        let kHz = String(format: "%g", Double(audio.sampleRate) / 1000)
        let text = "\(kHz) kHz, \(audio.channelCount) ch, int16"
        return audio.channelCount > 1 ? text + ", mixed to mono" : text
    }
}
