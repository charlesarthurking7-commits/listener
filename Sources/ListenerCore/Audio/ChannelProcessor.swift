/// What one 100 ms frame of a channel produced.
struct FrameReport: Sendable {
    var frame: ChannelFrame
    var activity: [VoiceActivity]
    /// What goes to speech-to-text now: usually just this frame; nothing while silence
    /// is being skipped; held-back pre-roll plus this frame when speech starts.
    var toSpeech: [ChannelFrame]
    /// Set on the one frame where the channel has been nothing but digital silence for
    /// `ChannelProcessor.silenceAlarmSeconds` since it started.
    var silenceAlarm = false

    var speechSeconds: Double { toSpeech.reduce(0) { $0 + $1.duration } }
}

/// One channel's audio path in front of speech-to-text: 100 ms framing, voice activity,
/// optional silence skipping and the digital-silence check. Plain synchronous code, so
/// it runs on the channel's own task and never waits on anything.
struct ChannelProcessor {
    /// A real microphone or a playing call never produces exact zeros for this long. A
    /// channel that has, since it started, almost certainly lacks a permission.
    static let silenceAlarmSeconds = 30.0

    private var framer = AudioFramer()
    private var detector: VoiceActivityDetector
    private var gate: SilenceGate?
    private var sampleCount = 0
    private var heardSound = false
    private var alarmRaised = false
    private var last: (speaker: Speaker, capturedAt: ContinuousClock.Instant)?

    init(turns: TurnSettings, skipSilence: Bool) {
        detector = VoiceActivityDetector(settings: turns)
        gate = skipSilence ? SilenceGate() : nil
    }

    mutating func process(_ chunk: AudioChunk) -> [FrameReport] {
        last = (chunk.speaker, chunk.capturedAt)
        return framer.push(chunk).map { analyse($0) }
    }

    /// The channel has ended: the last partial frame, and the end of speech still going.
    mutating func finish() -> [FrameReport] {
        var reports: [FrameReport] = []
        if let rest = framer.flush() {
            reports.append(analyse(rest))
        }
        if let end = detector.finish() {
            if reports.isEmpty, let last {
                let empty = AudioChunk(speaker: last.speaker, samples: [], capturedAt: last.capturedAt)
                reports.append(
                    FrameReport(frame: ChannelFrame(chunk: empty, start: position), activity: [], toSpeech: []))
            }
            if !reports.isEmpty {
                reports[reports.count - 1].activity.append(end)
            }
        }
        return reports
    }

    private var position: Double { Double(sampleCount) / Double(AudioChunk.sampleRate) }

    private mutating func analyse(_ chunk: AudioChunk) -> FrameReport {
        let frame = ChannelFrame(chunk: chunk, start: position)
        sampleCount += chunk.samples.count
        let activity = detector.process(chunk.samples)
        let toSpeech = gate?.admit(frame, activity: activity) ?? [frame]
        var report = FrameReport(frame: frame, activity: activity, toSpeech: toSpeech)

        if !heardSound {
            heardSound = !LevelMeter.isDigitalSilence(chunk.samples)
            if !heardSound && !alarmRaised && position >= Self.silenceAlarmSeconds {
                alarmRaised = true
                report.silenceAlarm = true
            }
        }
        return report
    }
}
