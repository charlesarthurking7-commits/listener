import Foundation
import Testing

@testable import ListenerCore

/// Calls generated at random, with overlaps, short pauses, finals that come late and
/// finals without start times (Chirp 3 without word timings), checked against what the
/// script says the turns should be. The seeds are ones that caught bugs, out of 300
/// that now all pass.
struct RandomCallTests {
    static let seeds: [UInt64] = [1, 3, 9, 14, 26, 44, 61, 85, 122, 129, 139, 141, 191, 215, 228, 231, 258]

    @Test(arguments: seeds)
    func turnsFollowTheScript(seed: UInt64) async throws {
        var random = SplitMix(state: seed)
        let script = Self.script(using: &random)
        // Finals from 0.3 s to 1.5 s after the speech, so some arrive after a turn's silence.
        let finalDelay = 0.3 + Double(seed % 7) * 0.2
        let root = try temporaryDirectory("random")
        defer { try? FileManager.default.removeItem(at: root) }
        var sources: [Speaker: ReplaySource] = [:]
        for speaker in Speaker.allCases {
            let audio = scriptAudio(script, speaker: speaker, seconds: (script.lines.last?.end ?? 0) + 2)
            sources[speaker] = try ReplaySource(audio: audio, speaker: speaker, pacing: .unpaced)
        }
        let session = CallSession(
            settings: sessionSettings(directory: root),
            components: SessionComponents(
                sources: sources,
                speech: StartlessSpeech(ScriptedSpeechToText(script: script, finalDelay: finalDelay)),
                languageModel: nil))
        try await session.start()
        await waitForReplay(sources)
        await session.stop()

        let turns = await session.transcript.turns
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
        #expect(try SessionStore.readTurns(in: try #require(await session.directory)) == turns)
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
    /// A line joins its speaker's turn when that turn is the latest one, the pause is
    /// shorter than the silence threshold and nobody else spoke in it. A pause shorter
    /// than the detector's hangover is not heard at all, so it never splits a turn, even
    /// with the other speaker talking over it.
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
                if gap < hangover || (gap < silence && !interrupted && index == turns.count - 1) {
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

/// Finals without a start time, like Chirp 3 without word timings or voice events, so
/// where speech began has to come from voice activity.
struct StartlessSpeech: SpeechToTextProvider {
    let inner: ScriptedSpeechToText

    init(_ inner: ScriptedSpeechToText) {
        self.inner = inner
    }

    var displayName: String { "Startless" }

    func openStream(for speaker: Speaker) async throws -> any SpeechStream {
        StartlessStream(try await inner.openStream(for: speaker))
    }
}

final class StartlessStream: SpeechStream {
    let events: AsyncThrowingStream<SpeechEvent, any Error>
    private let inner: any SpeechStream

    init(_ inner: any SpeechStream) {
        self.inner = inner
        let source = inner.events
        events = AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await var event in source {
                        event.audioStart = nil
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func send(_ chunk: AudioChunk) async throws {
        try await inner.send(chunk)
    }

    func finish() async {
        await inner.finish()
    }
}
