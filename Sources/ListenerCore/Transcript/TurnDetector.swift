import Foundation

/// Builds speaker turns from each channel's speech-to-text results and voice activity
/// (PLAN 3.5).
///
/// Results and voice activity arrive in channel time, seconds of that channel's audio.
/// `audioProgress` says when each stretch of audio was captured, which maps channel time
/// onto session time, so turns from both channels line up even when one channel's
/// results arrive late. Turns are kept in order of start time; ids are handed out in
/// order of creation and never change.
///
/// A turn grows while its speaker's finals follow each other with gaps shorter than
/// `silenceMs` and nobody else speaks in between or starts a turn during it. It closes, and never changes again,
/// once its final is in and the speaker's voice activity has seen `silenceMs` of
/// silence after it (which it can only be sure of `minSpeechMs` later), or when the
/// speaker starts a new turn. Speech the speaker went on with that has no final yet may
/// still belong to the turn, so the turn waits up to `finalGrace` longer for that final.
///
/// Where a final's speech began comes from the voice activity detector when it can:
/// recognisers often report no start, or the end of the previous final (Chirp 3 has no
/// word timings when streaming), which would make every pause look like no pause.
public struct TurnDetector: Sendable {
    public struct Update: Sendable, Equatable {
        /// The snapshot changed: a new or longer turn, or different interim text.
        public var changed = false
        /// Turns that just closed, in the order they closed.
        public var closed: [Turn] = []
    }

    public private(set) var snapshot = TranscriptSnapshot()
    /// Goes up whenever final text changes, so a caller can tell whether anything new
    /// has been said since it last looked.
    public private(set) var revision = 0

    /// A turn that has not grown for this much of its channel's audio closes even if
    /// the voice activity detector still hears sound, so a noisy channel cannot hold a
    /// turn open (and off disk) for the whole call.
    static let staleAfter = 15.0
    /// How much longer than `silenceMs` a turn waits for the final of speech that
    /// followed it, in seconds of session time. Recognisers can take well over a
    /// second; speech that has had no final by then (a cough, a noise) was not words.
    static let finalGrace = 2.0
    /// Recognisers make up short fillers ("Yeah.", "Okay.") in near silence. Text of at
    /// most this many words with no speech under it is taken for one and dropped. Longer
    /// text is kept: it is more likely speech too quiet for the voice activity detector.
    static let madeUpMaxWords = 3
    /// How far a recogniser's word times and the detector's speech may disagree.
    static let wordTimingSlack = 0.1

    private let silence: Double
    /// How long the voice activity detector takes to report speech after it starts:
    /// silence is only certain once a start that came within it would have shown.
    private let confirmation: Double
    private var channels: [Speaker: Channel] = [:]
    private var nextID = 1

    /// Speech the voice activity detector heard, in channel time.
    private struct Speech {
        var start: Double
        /// Nil while it goes on.
        var end: Double?
    }

    private struct Channel {
        var clock = CaptureClock()
        var position = 0.0
        /// Recent speech, oldest first, at most `speechKept` of it.
        var speech: [Speech] = []
        /// Channel time where the last final's audio ended.
        var lastFinalEnd = 0.0
        var openTurn: OpenTurn?

        var speaking: Bool { speech.last.map { $0.end == nil } ?? false }
        var lastSpeechEnd: Double? { speech.last { $0.end != nil }?.end }
        /// Speech went on after the last final ended, after a pause or straight on, and no
        /// final has covered it yet.
        var awaitingFinal: Bool {
            guard let last = speech.last else {
                return false
            }
            return last.start >= lastFinalEnd - Self.slack || (last.end ?? .infinity) > lastFinalEnd + Self.endSlack
        }

        /// Speech starting a hair before the previous final's end is still new speech:
        /// the recogniser and the detector rarely agree to the frame.
        static let slack = 0.05
        /// Where the detector hears speech end can lie a few tenths of a second past the
        /// end of the final that covers it: breath, room sound.
        static let endSlack = 0.3
        static let speechKept = 64

        mutating func record(_ frame: Range<Double>, capturedAt: Double) {
            if position == 0 {
                // Nothing before the first frame to interpolate from: assume real time.
                clock.record(audio: frame.lowerBound, session: capturedAt - (frame.upperBound - frame.lowerBound))
            }
            clock.record(audio: frame.upperBound, session: capturedAt)
            position = max(position, frame.upperBound)
        }

        mutating func apply(_ activity: VoiceActivity) {
            switch activity {
            case .speechStarted(let start):
                speech.append(Speech(start: start))
                if speech.count > Self.speechKept {
                    speech.removeFirst()
                }
            case .speechEnded(let end):
                if let last = speech.indices.last, speech[last].end == nil {
                    speech[last].end = max(end, speech[last].start)
                }
            }
        }

        /// Where the speech behind a final ending at `end` began: the first speech heard
        /// from the recogniser's start on, else the recogniser's start, else the speech
        /// that was going on, but never before the previous final.
        ///
        /// Recognisers put the start early: Apple counts seconds of the silence before
        /// the first word, Chirp 3 reports the previous final's end. The first sound
        /// since the previous final could be a cough or a keyboard minutes before the
        /// words, which would stretch a "Yeah." over the other side's whole answer.
        func speechStart(before end: Double, reported: Double?) -> Double {
            let from = max(lastFinalEnd, reported ?? lastFinalEnd)
            let fresh = speech.first {
                $0.start >= lastFinalEnd - Self.slack && $0.start < end && ($0.end ?? .infinity) > from
            }
            if let fresh {
                return fresh.start
            }
            if let reported {
                return min(reported, end)
            }
            if let current = speech.last(where: { $0.start < end }) {
                return min(max(current.start, lastFinalEnd), end)
            }
            return end
        }

        /// Whether the detector heard speech overlapping `start...end` of channel time.
        /// Audio older than the speech kept counts as heard, since nothing shows otherwise.
        func heard(from start: Double, to end: Double) -> Bool {
            if speech.count == Self.speechKept, let oldest = speech.first, oldest.start > start {
                return true
            }
            return speech.contains { $0.start < end && ($0.end ?? position) > start }
        }

        /// Whether this channel's speech overlaps `start...end` of session time. Speech
        /// still going on counts up to the audio the channel has delivered: a channel
        /// that lags behind the other has said nothing yet about what came after.
        func spoke(between start: Double, and end: Double) -> Bool {
            let heardUntil = clock.sessionTime(at: position)
            return speech.contains { segment in
                let from = clock.sessionTime(at: segment.start)
                let to = segment.end.map { clock.sessionTime(at: $0) } ?? heardUntil
                return from < end && to > start
            }
        }
    }

    private struct OpenTurn {
        var id: Int
        /// Channel time of the end of the turn's last final.
        var end: Double
    }

    public init(settings: TurnSettings) {
        silence = Double(settings.silenceMs) / 1000
        let frames = (max(settings.minSpeechMs, 1) * VoiceActivityDetector.framesPerSecond + 999) / 1000
        confirmation = Double(frames) * VoiceActivityDetector.frameDuration
    }

    /// The channel's audio over `frame` (channel seconds) has been analysed, its last
    /// sample was captured at `capturedAt` (session seconds), and the voice activity
    /// detector found `activity` in it. Taking both at once means a turn is never closed
    /// for silence that the frame's own speech start ends.
    public mutating func audioProgress(
        _ speaker: Speaker, frame: Range<Double>, capturedAt: Double, activity: [VoiceActivity] = []
    ) -> Update {
        // Mutated in place: this runs for every frame of every channel.
        channels[speaker, default: Channel()].record(frame, capturedAt: capturedAt)
        for change in activity {
            channels[speaker]?.apply(change)
        }
        var update = Update()
        closeIfFinished(speaker, &update)
        return update
    }

    public mutating func voiceActivity(_ activity: VoiceActivity, speaker: Speaker) -> Update {
        channels[speaker, default: Channel()].apply(activity)
        var update = Update()
        closeIfFinished(speaker, &update)
        return update
    }

    /// An empty interim clears the speaker's interim text; an empty final only does that.
    /// Text without a letter or digit counts as empty, and so does a made-up filler
    /// (`madeUpMaxWords`).
    public mutating func speechEvent(_ event: SpeechEvent, speaker: Speaker) -> Update {
        var update = Update()
        var text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains(where: { $0.isLetter || $0.isNumber }) || isMadeUp(text, event, speaker: speaker) {
            text = ""
        }
        switch event.kind {
        case .interim:
            update.changed = setInterim(text, for: speaker)
        case .final:
            update.changed = setInterim("", for: speaker)
            if !text.isEmpty {
                addFinal(text, audioStart: event.audioStart, audioEnd: event.audioEnd, speaker: speaker, &update)
                update.changed = true
            }
        }
        closeIfFinished(speaker, &update)
        return update
    }

    /// The call has ended: interim text that never got a final becomes a turn, and
    /// every open turn closes.
    public mutating func finish() -> Update {
        var update = Update()
        for speaker in Speaker.allCases {
            if let interim = snapshot.interim.removeValue(forKey: speaker) {
                addFinal(interim, audioStart: nil, audioEnd: nil, speaker: speaker, &update)
                update.changed = true
            }
            if let open = channels[speaker]?.openTurn, let index = index(of: open.id) {
                channels[speaker]?.openTurn = nil
                update.closed.append(snapshot.turns[index])
            }
        }
        update.closed.sort { $0.start < $1.start }
        return update
    }

    /// Only audio the detector has analysed can show that nobody spoke, so text without
    /// an end time, or ending past what the channel has delivered, is never made up.
    private func isMadeUp(_ text: String, _ event: SpeechEvent, speaker: Speaker) -> Bool {
        guard let channel = channels[speaker], let end = event.audioEnd, end <= channel.position,
            text.split(whereSeparator: \.isWhitespace).count <= Self.madeUpMaxWords
        else {
            return false
        }
        let start = min(event.audioStart ?? channel.lastFinalEnd, end)
        return !channel.heard(from: start - Self.wordTimingSlack, to: end + Self.wordTimingSlack)
    }

    /// Session time of a point on a channel's audio.
    public func sessionTime(_ speaker: Speaker, channelTime: Double) -> Double {
        channels[speaker]?.clock.sessionTime(at: channelTime) ?? channelTime
    }

    private mutating func setInterim(_ text: String, for speaker: Speaker) -> Bool {
        guard (snapshot.interim[speaker] ?? "") != text else {
            return false
        }
        snapshot.interim[speaker] = text.isEmpty ? nil : text
        return true
    }

    private mutating func addFinal(
        _ text: String, audioStart: Double?, audioEnd: Double?, speaker: Speaker, _ update: inout Update
    ) {
        var channel = channels[speaker, default: Channel()]
        // Without an end from the recogniser, the voice activity says where the speech was.
        let fallbackEnd = channel.speaking ? channel.position : (channel.lastSpeechEnd ?? channel.position)
        let endOnChannel = audioEnd ?? fallbackEnd
        let startOnChannel = channel.speechStart(before: endOnChannel, reported: audioStart)
        channel.lastFinalEnd = max(channel.lastFinalEnd, endOnChannel)
        let start = channel.clock.sessionTime(at: startOnChannel)
        let end = max(channel.clock.sessionTime(at: endOnChannel), start)

        if let open = channel.openTurn, let index = index(of: open.id),
            canExtend(snapshot.turns[index], ending: open.end, from: startOnChannel, at: start)
        {
            snapshot.turns[index].text += " " + text
            snapshot.turns[index].end = max(snapshot.turns[index].end, end)
            channel.openTurn?.end = max(open.end, endOnChannel)
        } else {
            if let open = channel.openTurn, let index = index(of: open.id) {
                update.closed.append(snapshot.turns[index])
            }
            let turn = Turn(id: nextID, speaker: speaker, text: text, start: start, end: end)
            nextID += 1
            insert(turn)
            channel.openTurn = OpenTurn(id: turn.id, end: endOnChannel)
        }
        channels[speaker] = channel
        revision += 1
    }

    /// Whether speech starting at `startOnChannel` (`start` in session time) continues
    /// `turn`, whose last final ended at `end` on the channel. The pause is measured in
    /// the channel's audio, so replay at any speed splits turns where a live call would.
    ///
    /// A reply that started while the turn was going on ("Yeah.") also ends it: what
    /// the speaker says after the reply must come after it, or a question asked then
    /// reads as already answered.
    private func canExtend(_ turn: Turn, ending end: Double, from startOnChannel: Double, at start: Double) -> Bool {
        startOnChannel - end < silence && !someoneElseSpoke(after: turn.end, before: start, besides: turn.speaker)
            && !snapshot.turns.contains { $0.speaker != turn.speaker && $0.start > turn.start && $0.start < start }
    }

    private func someoneElseSpoke(after gapStart: Double, before gapEnd: Double, besides speaker: Speaker) -> Bool {
        guard gapEnd > gapStart else {
            return false
        }
        let otherTurns = snapshot.turns.lazy.filter { $0.speaker != speaker }
        if otherTurns.contains(where: { $0.start < gapEnd && $0.end > gapStart }) {
            return true
        }
        return channels.contains { other, channel in
            other != speaker && channel.spoke(between: gapStart, and: gapEnd)
        }
    }

    private mutating func closeIfFinished(_ speaker: Speaker, _ update: inout Update) {
        guard let channel = channels[speaker], let open = channel.openTurn else {
            return
        }
        let quietSince = max(open.end, channel.lastSpeechEnd ?? open.end)
        let silenceOver = quietSince + silence + confirmation
        var silent = !channel.speaking && channel.position >= silenceOver
        if silent && channel.awaitingFinal {
            // A recogniser's delay is real time, not audio, which replay at speed packs
            // into more audio: the grace is measured on the session clock.
            let clock = channel.clock
            silent = clock.sessionTime(at: channel.position) - clock.sessionTime(at: silenceOver) >= Self.finalGrace
        }
        let stale = channel.position - open.end >= Self.staleAfter
        guard silent || stale, let index = index(of: open.id) else {
            return
        }
        channels[speaker]?.openTurn = nil
        update.closed.append(snapshot.turns[index])
    }

    private func index(of id: Int) -> Int? {
        snapshot.turns.lastIndex { $0.id == id }
    }

    private mutating func insert(_ turn: Turn) {
        let position = (snapshot.turns.lastIndex { $0.start <= turn.start } ?? -1) + 1
        snapshot.turns.insert(turn, at: position)
    }
}
