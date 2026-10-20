import Foundation

/// Builds speaker turns from each channel's speech-to-text results and voice activity
/// (PLAN 4.5).
///
/// Results and voice activity arrive in channel time, seconds of that channel's audio.
/// `audioProgress` says when each stretch of audio was captured, which maps channel time
/// onto session time, so turns from both channels line up even when one channel's
/// results arrive late. Turns are kept in order of start time; ids are handed out in
/// order of creation and never change.
///
/// A turn grows while its speaker's finals follow each other with gaps shorter than
/// `silenceMs` and nobody else speaks in between. It closes, and never changes again,
/// once its final is in and the speaker's voice activity has seen `silenceMs` of
/// silence after it, or when the speaker starts a new turn.
public struct TurnDetector: Sendable {
    public struct Update: Sendable, Equatable {
        /// The snapshot changed: a new or longer turn, or different interim text.
        public var changed = false
        /// Turns that just closed, in the order they closed.
        public var closed: [Turn] = []

        public init(changed: Bool = false, closed: [Turn] = []) {
            self.changed = changed
            self.closed = closed
        }
    }

    public private(set) var snapshot = TranscriptSnapshot()
    /// Goes up whenever final text changes, so a caller can tell whether anything new
    /// has been said since it last looked.
    public private(set) var revision = 0

    /// A turn that has not grown for this much of its channel's audio closes even if
    /// the voice activity detector still hears sound, so a noisy channel cannot hold a
    /// turn open (and off disk) for the whole call.
    static let staleAfter = 15.0

    private let silence: Double
    private var channels: [Speaker: Channel] = [:]
    private var nextID = 1

    private struct Channel {
        var clock = CaptureClock()
        var position = 0.0
        var speaking = false
        var speechStart: Double?
        var lastSpeechEnd: Double?
        /// Recent speech in session time, oldest first.
        var recentSpeech: [ClosedRange<Double>] = []
        var openTurn: OpenTurn?

        mutating func record(_ frame: Range<Double>, capturedAt: Double) {
            if position == 0 {
                // Nothing before the first frame to interpolate from: assume real time.
                clock.record(audio: frame.lowerBound, session: capturedAt - (frame.upperBound - frame.lowerBound))
            }
            clock.record(audio: frame.upperBound, session: capturedAt)
            position = max(position, frame.upperBound)
        }
    }

    private struct OpenTurn {
        var id: Int
        /// Channel time of the end of the turn's last final.
        var end: Double
    }

    public init(settings: TurnSettings) {
        silence = Double(settings.silenceMs) / 1000
    }

    /// The channel's audio over `frame` (channel seconds) has been analysed, and its
    /// last sample was captured at `capturedAt` (session seconds).
    public mutating func audioProgress(_ speaker: Speaker, frame: Range<Double>, capturedAt: Double) -> Update {
        // Mutated in place: this runs for every frame of every channel.
        channels[speaker, default: Channel()].record(frame, capturedAt: capturedAt)
        var update = Update()
        closeIfFinished(speaker, &update)
        return update
    }

    public mutating func voiceActivity(_ activity: VoiceActivity, speaker: Speaker) -> Update {
        var channel = channels[speaker, default: Channel()]
        switch activity {
        case .speechStarted(let start):
            channel.speaking = true
            channel.speechStart = start
        case .speechEnded(let end):
            channel.speaking = false
            channel.lastSpeechEnd = end
            let start = channel.clock.sessionTime(at: channel.speechStart ?? end)
            let finish = channel.clock.sessionTime(at: end)
            channel.recentSpeech.append(min(start, finish)...max(start, finish))
            if channel.recentSpeech.count > 64 {
                channel.recentSpeech.removeFirst()
            }
        }
        channels[speaker] = channel
        var update = Update()
        closeIfFinished(speaker, &update)
        return update
    }

    public mutating func speechEvent(_ event: SpeechEvent, speaker: Speaker) -> Update {
        var update = Update()
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // Without times from the provider, the voice activity says where the speech was.
        let fallbackEnd = channel.speaking ? channel.position : (channel.lastSpeechEnd ?? channel.position)
        let endOnChannel = audioEnd ?? fallbackEnd
        let startOnChannel = min(audioStart ?? channel.speechStart ?? endOnChannel, endOnChannel)
        let start = channel.clock.sessionTime(at: startOnChannel)
        let end = max(channel.clock.sessionTime(at: endOnChannel), start)

        if let open = channel.openTurn, let index = index(of: open.id), canExtend(snapshot.turns[index], from: start) {
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

    private func canExtend(_ turn: Turn, from start: Double) -> Bool {
        start - turn.end < silence && !someoneElseSpoke(after: turn.end, before: start, besides: turn.speaker)
    }

    private func someoneElseSpoke(after gapStart: Double, before gapEnd: Double, besides speaker: Speaker) -> Bool {
        guard gapEnd > gapStart else {
            return false
        }
        let overlaps = { (range: ClosedRange<Double>) in range.lowerBound < gapEnd && range.upperBound > gapStart }
        for turn in snapshot.turns where turn.speaker != speaker && overlaps(turn.start...turn.end) {
            return true
        }
        for (other, channel) in channels where other != speaker {
            if channel.recentSpeech.contains(where: overlaps) {
                return true
            }
            if channel.speaking, let start = channel.speechStart, channel.clock.sessionTime(at: start) < gapEnd {
                return true
            }
        }
        return false
    }

    private mutating func closeIfFinished(_ speaker: Speaker, _ update: inout Update) {
        guard let channel = channels[speaker], let open = channel.openTurn else {
            return
        }
        let quietSince = max(open.end, channel.lastSpeechEnd ?? open.end)
        let silent = !channel.speaking && channel.position - quietSince >= silence
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
