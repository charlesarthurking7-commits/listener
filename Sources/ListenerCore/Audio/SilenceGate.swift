/// A frame of one channel's audio together with where it sits on that channel's timeline.
public struct ChannelFrame: Sendable {
    public var chunk: AudioChunk
    /// Seconds of the channel's audio before this frame's first sample.
    public var start: Double

    public init(chunk: AudioChunk, start: Double) {
        self.chunk = chunk
        self.start = start
    }

    public var duration: Double { Double(chunk.samples.count) / Double(AudioChunk.sampleRate) }
    public var end: Double { start + duration }
}

/// Decides which frames go to speech-to-text when silence skipping is on: only speech,
/// plus a pre-roll before it so word onsets are not clipped, and a tail after it so the
/// recogniser hears the pause it needs to finalise.
///
/// The voice activity detector only confirms speech after `minSpeechMs`, and reports it
/// from where it began, so recent silent frames are held back and the ones from
/// `preRoll` before the onset are released when speech is confirmed.
public struct SilenceGate: Sendable {
    public let preRoll: Double
    public let tail: Double

    private var held: [ChannelFrame] = []
    private var openUntil: Double?
    // Enough to reach back past the slowest confirmation the detector can make.
    private let holdSeconds: Double

    public init(preRoll: Double = 0.3, tail: Double = 1.0) {
        self.preRoll = preRoll
        self.tail = tail
        holdSeconds = preRoll + 2.5
    }

    /// Takes the next frame and the voice activity found in it, and returns the frames
    /// to send now, oldest first.
    public mutating func admit(_ frame: ChannelFrame, activity: [VoiceActivity]) -> [ChannelFrame] {
        var released: [ChannelFrame] = []
        for change in activity {
            switch change {
            case .speechStarted(let onset):
                openUntil = .infinity
                released.append(contentsOf: held.filter { $0.end > onset - preRoll })
                held.removeAll(keepingCapacity: true)
            case .speechEnded(let end):
                openUntil = end + tail
            }
        }

        if let openUntil, frame.start < openUntil {
            released.append(frame)
            return released
        }
        openUntil = nil
        held.append(frame)
        let oldestKept = frame.end - holdSeconds
        if let firstKept = held.firstIndex(where: { $0.end > oldestKept }), firstKept > 0 {
            held.removeFirst(firstKept)
        }
        return released
    }
}
