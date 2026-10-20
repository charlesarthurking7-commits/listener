/// Maps a channel's audio position onto session time from when each frame was
/// captured, interpolating between frames. It follows capture gaps, clock drift and
/// replay at any speed, where audio time runs faster than session time.
///
/// Only the most recent `capacity` frames are kept, which covers anything a recogniser
/// can still report on; older times are extrapolated from the oldest kept frame.
public struct CaptureClock: Sendable, Equatable {
    private struct Point: Sendable, Equatable {
        var audio: Double
        var session: Double
    }

    public let capacity: Int
    private var points: [Point] = []

    /// The default keeps ten minutes of 100 ms frames.
    public init(capacity: Int = 6_000) {
        self.capacity = max(capacity, 2)
    }

    /// Records that the sample at `audio` seconds of the channel was captured at
    /// `session` seconds. Points must come in increasing audio order; others are ignored.
    public mutating func record(audio: Double, session: Double) {
        if let last = points.last, audio <= last.audio {
            return
        }
        points.append(Point(audio: audio, session: session))
        // Trimmed in batches so recording stays O(1) on average.
        if points.count >= 2 * capacity {
            points.removeFirst(points.count - capacity)
        }
    }

    /// Session time of `audio`. Outside the recorded span, time runs at the real-time
    /// rate from the nearest point; with nothing recorded this is the identity.
    public func sessionTime(at audio: Double) -> Double {
        guard let first = points.first, let last = points.last else {
            return audio
        }
        if audio <= first.audio {
            return first.session - (first.audio - audio)
        }
        if audio >= last.audio {
            return last.session + (audio - last.audio)
        }
        var low = 0
        var high = points.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if points[middle].audio <= audio {
                low = middle
            } else {
                high = middle
            }
        }
        let before = points[low]
        let after = points[high]
        let fraction = (audio - before.audio) / (after.audio - before.audio)
        return before.session + (after.session - before.session) * fraction
    }
}
