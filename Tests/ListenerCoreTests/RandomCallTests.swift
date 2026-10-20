import Foundation
import Testing

@testable import ListenerCore

/// Calls generated at random, with overlaps, short pauses, finals that come late and
/// finals without start times (Chirp 3 without word timings), checked against what the
/// script says the turns should be. The seeds are ones that caught bugs, out of 1,000
/// that now all pass.
///
/// The turn detector is fed in lock step, 100 ms at a time, with what CallSession gives
/// it on a live call: the voice activity in each frame of synthesised audio, then
/// whatever the scripted recogniser says once it has that frame. There are no tasks and
/// no clock, so the outcome never depends on how busy the machine is.
struct RandomCallTests {
    static let seeds: [UInt64] = [1, 3, 9, 14, 26, 44, 61, 85, 122, 129, 139, 141, 191, 215, 228, 231, 258]

    @Test(arguments: seeds)
    func turnsFollowTheScript(seed: UInt64) {
        var random = SplitMix(state: seed)
        let script = Self.script(using: &random)
        // Finals from 0.3 s to 1.5 s after the speech, so some arrive after a turn's silence.
        let finalDelay = 0.3 + Double(seed % 7) * 0.2
        let turns = Self.detectTurns(in: script, finalDelay: finalDelay)

        #expect(turns.map(\.start) == turns.map(\.start).sorted())
        if let expected = Self.expectedTurns(script) {
            #expect(turns.map(\.text) == expected)
        } else {
            // A pause too close to a threshold to call: each speaker's words still come
            // out complete and in order.
            for speaker in Speaker.allCases {
                let said = script.lines.filter { $0.speaker == speaker }.map(\.text)
                let heard = turns.filter { $0.speaker == speaker }.map(\.text)
                #expect(heard.joined(separator: " ") == said.joined(separator: " "))
            }
        }
    }

    /// One channel as CallSession runs it: audio through the frame processor, then the
    /// recogniser, whose finals carry no start time.
    private struct Channel {
        let speaker: Speaker
        let chunks: [AudioChunk]
        var processor: ChannelProcessor
        var recognizer: ScriptRecognizer
    }

    static func detectTurns(in script: ConversationScript, finalDelay: Double) -> [Turn] {
        let settings = TurnSettings()
        let seconds = (script.lines.last?.end ?? 0) + 2
        var detector = TurnDetector(settings: settings)
        var channels = Speaker.allCases.map { speaker in
            Channel(
                speaker: speaker,
                chunks: scriptAudio(script, speaker: speaker, seconds: seconds).samples
                    .chunks(of: AudioChunk.sampleRate / 10, speaker: speaker),
                processor: ChannelProcessor(turns: settings, skipSilence: false),
                recognizer: ScriptRecognizer(
                    lines: script.lines.filter { $0.speaker == speaker }, finalDelay: finalDelay))
        }

        func deliver(_ reports: [FrameReport], _ events: [SpeechEvent], from speaker: Speaker) {
            for report in reports {
                let frame = report.frame
                _ = detector.audioProgress(
                    speaker, frame: frame.start..<frame.end, capturedAt: frame.end, activity: report.activity)
            }
            for var event in events {
                event.audioStart = nil
                _ = detector.speechEvent(event, speaker: speaker)
            }
        }

        for index in channels[0].chunks.indices {
            for channel in channels.indices {
                let reports = channels[channel].processor.process(channels[channel].chunks[index])
                let heard = channels[channel].recognizer.advance(to: reports.last?.frame.end ?? 0)
                deliver(reports, heard, from: channels[channel].speaker)
            }
        }
        for channel in channels.indices {
            let reports = channels[channel].processor.finish()
            deliver(reports, channels[channel].recognizer.finish(at: seconds), from: channels[channel].speaker)
        }
        _ = detector.finish()
        return detector.snapshot.turns
    }

    /// Fourteen lines, the speaker changing most of the time, with pauses from a
    /// 0.4 s overlap (only between speakers) to 1.5 s.
    static func script(using random: inout SplitMix) -> ConversationScript {
        var lines: [ConversationScript.Line] = []
        var speaker = Speaker.them
        for index in 0..<14 {
            let previous = lines.last
            if Double.random(in: 0..<1, using: &random) < 0.7 {
                speaker = speaker == .me ? .them : .me
            }
            var gap = Double.random(in: -0.4...1.5, using: &random)
            if previous?.speaker == speaker {
                gap = max(gap, 0.25)
            }
            let start = max((previous?.end ?? 0.5) + gap, (previous?.start ?? 0) + 0.3)
            let end = start + Double.random(in: 0.4...3, using: &random)
            lines.append(.init(speaker: speaker, start: start, end: end, text: "Line \(index) from \(speaker)."))
        }
        return ConversationScript(title: "random", lines: lines)
    }

    /// What the turns should be, or nil when a pause is too close to a threshold to say.
    /// A line joins its speaker's last turn when the pause is shorter than the silence
    /// threshold and nobody else spoke in it. A pause shorter than the detector's
    /// hangover is not heard at all, so it never splits a turn, even with the other
    /// speaker talking over it.
    static func expectedTurns(_ script: ConversationScript) -> [String]? {
        let silence = Double(TurnSettings().silenceMs) / 1000
        let hangover = 0.2
        var turns: [(speaker: Speaker, text: String, end: Double)] = []
        var latest: [Speaker: Int] = [:]
        for line in script.lines {
            if let index = latest[line.speaker] {
                let previous = turns[index]
                let gap = line.start - previous.end
                if abs(gap - silence) < 0.05 || abs(gap - hangover) < 0.03 {
                    return nil
                }
                let interrupted = script.lines.contains {
                    $0.speaker != line.speaker && $0.start < line.start && $0.end > previous.end
                }
                if gap < hangover || (gap < silence && !interrupted) {
                    turns[index].text += " " + line.text
                    turns[index].end = max(previous.end, line.end)
                    continue
                }
            }
            turns.append((line.speaker, line.text, line.end))
            latest[line.speaker] = turns.count - 1
        }
        return turns.map(\.text)
    }
}

/// splitmix64, so the calls are the same on every machine.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
