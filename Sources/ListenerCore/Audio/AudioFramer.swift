/// Re-cuts a channel's audio into equal frames, 100 ms (1,600 samples) by default,
/// whatever sizes the capture device delivers. Speech-to-text gets steady 100 ms
/// requests, and every frame's `capturedAt` is the capture time of its last sample,
/// interpolated within the chunk it came from.
public struct AudioFramer: Sendable {
    public static let defaultFrameLength = AudioChunk.sampleRate / 10

    public let frameLength: Int
    private var pending: [Int16] = []
    private var last: (speaker: Speaker, capturedAt: ContinuousClock.Instant)?

    public init(frameLength: Int = defaultFrameLength) {
        precondition(frameLength > 0, "frames need at least one sample")
        self.frameLength = frameLength
        pending.reserveCapacity(frameLength)
    }

    /// Samples waiting for the next frame.
    public var pendingCount: Int { pending.count }

    public mutating func push(_ chunk: AudioChunk) -> [AudioChunk] {
        last = (chunk.speaker, chunk.capturedAt)
        let samples = chunk.samples
        if pending.isEmpty && samples.count == frameLength {
            return [chunk]
        }

        var frames: [AudioChunk] = []
        var index = 0
        while index < samples.count {
            let end = min(index + frameLength - pending.count, samples.count)
            pending.append(contentsOf: samples[index..<end])
            index = end
            if pending.count == frameLength {
                // The chunk's capture time belongs to its last sample; this frame ended
                // `samples.count - index` samples earlier.
                let earlier = Duration.seconds(Double(samples.count - index) / Double(AudioChunk.sampleRate))
                frames.append(
                    AudioChunk(speaker: chunk.speaker, samples: pending, capturedAt: chunk.capturedAt - earlier))
                pending = []
                pending.reserveCapacity(frameLength)
            }
        }
        return frames
    }

    /// The leftover samples as a short final frame, once the channel has ended.
    public mutating func flush() -> AudioChunk? {
        guard !pending.isEmpty, let last else {
            return nil
        }
        defer { pending = [] }
        return AudioChunk(speaker: last.speaker, samples: pending, capturedAt: last.capturedAt)
    }
}
