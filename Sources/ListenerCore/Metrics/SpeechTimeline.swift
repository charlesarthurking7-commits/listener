/// Recent speech on each channel in session time, and when speech-to-text finalised it.
/// Answer latency is measured from here: the end of speech is the last speech the local
/// voice activity detector heard on Them, or on Me when Them has said nothing yet.
struct SpeechTimeline {
    struct Segment: Sendable, Equatable {
        let id: Int
        let speaker: Speaker
        var start: Double
        var end: Double?
        /// When the final covering this speech arrived.
        var finalAt: Double?
    }

    /// How far speech may run past a final's audio end and still count as covered by it.
    /// The detector's end and the recogniser's end of words rarely agree exactly.
    static let tolerance = 0.5
    private static let kept = 64

    private(set) var segments: [Segment] = []
    private var nextID = 1

    mutating func speechStarted(_ speaker: Speaker, at time: Double) {
        segments.append(Segment(id: nextID, speaker: speaker, start: time))
        nextID += 1
        if segments.count > Self.kept {
            segments.removeFirst()
        }
    }

    mutating func speechEnded(_ speaker: Speaker, at time: Double) {
        if let index = segments.lastIndex(where: { $0.speaker == speaker && $0.end == nil }) {
            segments[index].end = max(time, segments[index].start)
        }
    }

    /// A final for audio up to `audioEnd` (nil: unknown) arrived at `arrivedAt`. Marks
    /// the finished speech it covers and returns those segments' ids.
    mutating func finalArrived(_ speaker: Speaker, audioEnd: Double?, at arrivedAt: Double) -> [Int] {
        var covered: [Int] = []
        for index in segments.indices {
            let segment = segments[index]
            guard segment.speaker == speaker, segment.finalAt == nil, let end = segment.end else {
                continue
            }
            if let audioEnd, end > audioEnd + Self.tolerance {
                continue
            }
            segments[index].finalAt = arrivedAt
            covered.append(segment.id)
        }
        return covered
    }

    /// The speech an answer asked for now is measured from.
    func endOfSpeech() -> Segment? {
        lastFinished(.them) ?? lastFinished(.me)
    }

    private func lastFinished(_ speaker: Speaker) -> Segment? {
        segments.last { $0.speaker == speaker && $0.end != nil }
    }
}
