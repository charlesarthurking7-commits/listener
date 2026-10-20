/// Recent speech on each channel in session time, and when speech-to-text finalised it.
/// Answer latency is measured from here: the end of speech is the end of the latest
/// speech the local voice activity detector heard on Them, or on Me when Them has said
/// nothing yet.
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

    /// Returns the speech that ended, if any was going on.
    @discardableResult
    mutating func speechEnded(_ speaker: Speaker, at time: Double) -> Segment? {
        guard let index = segments.lastIndex(where: { $0.speaker == speaker && $0.end == nil }) else {
            return nil
        }
        segments[index].end = max(time, segments[index].start)
        return segments[index]
    }

    func segment(_ id: Int) -> Segment? {
        segments.last { $0.id == id }
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

    /// The latest speech, on Them or else on Me. It may not have ended yet: the detector
    /// confirms an end only after a stretch of quiet.
    func endOfSpeech() -> Segment? {
        segments.last { $0.speaker == .them } ?? segments.last { $0.speaker == .me }
    }

    /// What an answer asked for now is measured from.
    func answerSpeech() -> AnswerSpeech? {
        guard let latest = endOfSpeech() else {
            return nil
        }
        guard latest.end == nil else {
            return AnswerSpeech(latest: latest, wasGoingOn: false)
        }
        return AnswerSpeech(latest: latest, wasGoingOn: true, earlier: lastFinished(.them) ?? lastFinished(.me))
    }

    private func lastFinished(_ speaker: Speaker) -> Segment? {
        segments.last { $0.speaker == speaker && $0.end != nil }
    }
}

/// The speech an answer is measured from: the speech the user was answering when the
/// hotkey went down.
///
/// That is the latest speech, even when it still seemed to be going on, since the
/// detector confirms the end of speech a fifth of a second late and a quick hotkey
/// comes before that. If it turns out to have gone on past the hotkey, the speaker had
/// started again (or was still talking), and the speech before it counts instead.
struct AnswerSpeech: Sendable, Equatable {
    var latest: SpeechTimeline.Segment
    /// `latest` had not been heard to end at the hotkey.
    var wasGoingOn: Bool
    /// The last speech that had ended at the hotkey, for when `latest` goes on past it.
    var earlier: SpeechTimeline.Segment?

    /// The speech that had ended by `hotkey`; nil until that is known, or if none had.
    func measured(hotkey: Double) -> SpeechTimeline.Segment? {
        guard let end = latest.end else {
            return nil
        }
        return !wasGoingOn || end <= hotkey ? latest : earlier
    }

    /// Nothing more about it can change: it is known which speech counts, and that
    /// speech has its final.
    func isComplete(hotkey: Double) -> Bool {
        latest.end != nil && measured(hotkey: hotkey).map { $0.finalAt != nil } ?? true
    }

    /// Takes the newer state of a segment. Returns whether it was one of this answer's.
    @discardableResult
    mutating func update(_ segment: SpeechTimeline.Segment) -> Bool {
        if latest.id == segment.id {
            latest = segment
            return true
        }
        if earlier?.id == segment.id {
            earlier = segment
            return true
        }
        return false
    }
}
