/// Keeps one channel's audio in step with the wall clock.
///
/// Speech-to-text and the turn detector treat a channel as one continuous signal whose
/// sample count is its clock. Capture sources do not always deliver one: ScreenCaptureKit
/// sends nothing while the Mac is silent, and a Core Audio tap or AVAudioEngine sends
/// nothing while it is being rebuilt. GapFiller turns those holes into digital silence.
///
/// Ordinary delivery jitter is left alone: silence only goes in once the source has been
/// quiet for longer than `threshold`, or after the source said its capture path was
/// rebuilt (`realign()`), however short the break. Real audio is never dropped, so a
/// buffer that turns up late, after the gap was already filled, puts the stream slightly
/// ahead of the wall clock until the next gap absorbs the difference.
public struct GapFiller: Sendable {
    public static let defaultThreshold: Duration = .milliseconds(250)
    /// Silence goes out in pieces no longer than this, so it looks like ordinary audio downstream.
    public static let fillChunkSamples = AudioChunk.sampleRate / 10

    public let speaker: Speaker
    public let threshold: Duration
    private let origin: ContinuousClock.Instant
    private var emittedSamples = 0
    private var lastArrival: ContinuousClock.Instant
    private var realignPending = false

    /// - Parameter origin: when the channel started; any quiet stretch after it counts as a gap.
    public init(speaker: Speaker, origin: ContinuousClock.Instant, threshold: Duration = defaultThreshold) {
        self.speaker = speaker
        self.threshold = threshold
        self.origin = origin
        lastArrival = origin
    }

    /// The wall-clock time the next sample belongs to, judging by how much audio went out.
    public var streamEnd: ContinuousClock.Instant {
        origin + SampleClock.duration(ofSamples: emittedSamples)
    }

    /// Passes a captured chunk through, preceded by silence if the source had been quiet
    /// for longer than the threshold before it.
    public mutating func accept(_ chunk: AudioChunk) -> [AudioChunk] {
        let start = chunk.capturedAt - SampleClock.duration(ofSamples: chunk.samples.count)
        var output = realignPending || start - lastArrival > threshold ? silence(until: start) : []
        realignPending = false
        output.append(chunk)
        emittedSamples += chunk.samples.count
        lastArrival = max(lastArrival, chunk.capturedAt)
        return output
    }

    /// Marks a break in the source's own timeline, such as a rebuilt capture path: the next
    /// chunk is preceded by whatever silence brings the stream back in line with the wall
    /// clock, even if the break was shorter than the threshold.
    public mutating func realign() {
        realignPending = true
    }

    /// Silence up to `now` if the source has been quiet for longer than the threshold.
    /// Called on a timer, so a channel whose source stopped delivering keeps flowing.
    public mutating func fill(until now: ContinuousClock.Instant) -> [AudioChunk] {
        if now - lastArrival <= threshold {
            return []
        }
        return silence(until: now)
    }

    private mutating func silence(until end: ContinuousClock.Instant) -> [AudioChunk] {
        var missing = SampleClock.samples(in: end - streamEnd)
        var pieces: [AudioChunk] = []
        while missing > 0 {
            let count = min(missing, Self.fillChunkSamples)
            emittedSamples += count
            missing -= count
            pieces.append(
                AudioChunk(speaker: speaker, samples: Array(repeating: 0, count: count), capturedAt: streamEnd))
        }
        return pieces
    }
}

/// Exact conversions between 16 kHz sample counts and durations. One sample is 62.5 µs,
/// a whole number of nanoseconds, so long streams do not accumulate rounding error.
enum SampleClock {
    static let nanosecondsPerSample: Int64 = 1_000_000_000 / Int64(AudioChunk.sampleRate)

    static func duration(ofSamples count: Int) -> Duration {
        .nanoseconds(Int64(count) * nanosecondsPerSample)
    }

    /// Whole samples that fit in `duration`; zero when it is not positive.
    static func samples(in duration: Duration) -> Int {
        if duration <= .zero {
            return 0
        }
        let (seconds, attoseconds) = duration.components
        let attosecondsPerSample = nanosecondsPerSample * 1_000_000_000
        return Int(seconds) * AudioChunk.sampleRate + Int(attoseconds / attosecondsPerSample)
    }
}
