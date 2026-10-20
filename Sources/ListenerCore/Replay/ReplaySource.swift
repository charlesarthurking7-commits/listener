import Foundation
import Synchronization

public enum ReplayError: Error, Equatable {
    case noSuchChannel(Int, channelCount: Int)
    case invalidSpeed(Double)
    case alreadyStarted
}

/// Plays a WAV file as if it were live capture: 16 kHz mono chunks of 100 ms, delivered
/// at the pace they would have been recorded (or faster with `speed`). Replay and tests
/// feed the whole pipeline through this, so it behaves exactly as it does on a call.
///
/// Each chunk's `capturedAt` is when its last sample would have been captured at the
/// chosen pace. Unpaced, chunks arrive as fast as they can be taken, still stamped at
/// real-time pace; transcript times then match the file, but latency numbers mean
/// nothing.
public final class ReplaySource: AudioCaptureSource, Sendable {
    public enum Channel: Sendable, Equatable {
        /// The average of every channel in the file.
        case mix
        /// One channel, counting from 0. A stereo call recording usually has Me on 0
        /// and Them on 1.
        case index(Int)
    }

    public enum Pacing: Sendable, Equatable {
        /// `speed` 1 is real time, 4 plays a minute of audio in 15 seconds.
        case realTime(speed: Double)
        case unpaced

        public static let realTime = Pacing.realTime(speed: 1)
    }

    public let speaker: Speaker
    public let audio: WAVAudio
    public let channel: Channel
    public let pacing: Pacing
    public let name: String

    private let playback = Mutex<Task<Void, Never>?>(nil)

    public init(
        audio: WAVAudio, speaker: Speaker, channel: Channel = .mix, pacing: Pacing = .realTime,
        name: String = "in-memory audio"
    ) throws {
        if case .index(let index) = channel, !(0..<audio.channelCount).contains(index) {
            throw ReplayError.noSuchChannel(index, channelCount: audio.channelCount)
        }
        if case .realTime(let speed) = pacing, !(speed > 0 && speed.isFinite) {
            throw ReplayError.invalidSpeed(speed)
        }
        // Fails now rather than at start() for a rate the resampler cannot handle.
        _ = try Resampler(inputRate: audio.sampleRate, channelCount: audio.channelCount)
        self.audio = audio
        self.speaker = speaker
        self.channel = channel
        self.pacing = pacing
        self.name = name
    }

    public convenience init(url: URL, speaker: Speaker, channel: Channel = .mix, pacing: Pacing = .realTime) throws {
        try self.init(
            audio: WAVReader.read(url: url), speaker: speaker, channel: channel, pacing: pacing,
            name: url.lastPathComponent)
    }

    public convenience init(url: URL, speaker: Speaker, speed: Double, channel: Channel = .mix) throws {
        try self.init(url: url, speaker: speaker, channel: channel, pacing: .realTime(speed: speed))
    }

    /// Seconds of audio in the file.
    public var duration: Double { Double(audio.frameCount) / Double(audio.sampleRate) }

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo {
        let (samples, channelCount) = selectedSamples()
        let freshResampler = try Resampler(inputRate: audio.sampleRate, channelCount: channelCount)
        let (speaker, pacing, frameCount, sampleRate) = (speaker, pacing, audio.frameCount, audio.sampleRate)

        try playback.withLock { playback in
            guard playback == nil else {
                throw ReplayError.alreadyStarted
            }
            // Taken now rather than when the task first runs, so two sources started one
            // after the other stay in step even on a busy machine.
            let origin = ContinuousClock.now
            playback = Task {
                await Self.play(
                    samples, channelCount: channelCount, frameCount: frameCount, sampleRate: sampleRate,
                    resampler: freshResampler, speaker: speaker, pacing: pacing, origin: origin, onChunk: onChunk)
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
        _ samples: [Int16], channelCount: Int, frameCount: Int, sampleRate: Int, resampler: Resampler,
        speaker: Speaker, pacing: Pacing, origin: ContinuousClock.Instant, onChunk: @Sendable (AudioChunk) -> Void
    ) async {
        var resampler = resampler
        let framesPerStep = max(sampleRate / 10, 1)
        let chunkLength = AudioChunk.sampleRate / 10
        var pending: [Int16] = []
        var delivered = 0
        var frame = 0
        while frame < frameCount {
            let end = min(frame + framesPerStep, frameCount)
            pending += resampler.process(Array(samples[frame * channelCount..<end * channelCount]))
            if end == frameCount {
                pending += resampler.flush()
            }
            frame = end
            // Exact 100 ms chunks, as a capture device would deliver them; the last may be short.
            while pending.count >= chunkLength || (frame == frameCount && !pending.isEmpty) {
                let count = min(chunkLength, pending.count)
                let chunk = Array(pending[..<count])
                pending.removeFirst(count)
                delivered += count
                let audioTime = Duration.seconds(Double(delivered) / Double(AudioChunk.sampleRate))
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
                onChunk(AudioChunk(speaker: speaker, samples: chunk, capturedAt: capturedAt))
            }
        }
    }

    private func selectedSamples() -> (samples: [Int16], channelCount: Int) {
        switch channel {
        case .index(let index) where audio.channelCount > 1:
            return (audio.channel(index), 1)
        default:
            return (audio.samples, audio.channelCount)
        }
    }

    private var formatDescription: String {
        let kHz = String(format: "%g", Double(audio.sampleRate) / 1000)
        var text = "\(kHz) kHz, \(audio.channelCount) ch, int16"
        if audio.channelCount > 1 {
            switch channel {
            case .mix: text += ", mixed to mono"
            case .index(let index): text += ", channel \(index)"
            }
        }
        return text
    }
}
