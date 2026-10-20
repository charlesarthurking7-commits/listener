import Testing

@testable import ListenerCore

struct ScriptedSpeechToTextTests {
    static let script = ConversationScript(
        title: "test",
        lines: [
            .init(speaker: .them, start: 1.0, end: 2.0, text: "how are the fills looking"),
            .init(speaker: .me, start: 2.5, end: 3.0, text: "all good"),
            .init(speaker: .them, start: 3.5, end: 4.5, text: "great thanks"),
        ])

    private func them() -> ScriptRecognizer {
        ScriptRecognizer(lines: Self.script.lines.filter { $0.speaker == .them }, finalDelay: 0.3)
    }

    @Test func interimGrowsWordByWordThenTheFinalComesAfterTheDelay() {
        var recognizer = them()
        var log: [(Double, SpeechEvent)] = []
        for step in 1...100 {
            let position = Double(step) / 20
            log += recognizer.advance(to: position).map { (position, $0) }
        }

        let interims = log.filter { $0.1.kind == .interim }.map(\.1.text)
        #expect(
            Array(interims.prefix(5)) == [
                "how", "how are", "how are the", "how are the fills", "how are the fills looking",
            ])
        let finals = log.filter { $0.1.kind == .final }
        #expect(finals.map(\.1.text) == ["how are the fills looking", "great thanks"])
        #expect(finals.map(\.0) == [2.3, 4.8])
        #expect(finals[0].1.audioStart == 1.0)
        #expect(finals[0].1.audioEnd == 2.0)
        #expect(log.first?.0 == 1.0)
    }

    @Test func finalsDoNotDependOnChunkSize() {
        func finals(step: Double) -> [SpeechEvent] {
            var recognizer = them()
            var events: [SpeechEvent] = []
            var position = 0.0
            while position < 5 {
                position += step
                events += recognizer.advance(to: position)
            }
            return events.filter { $0.kind == .final }
        }
        #expect(finals(step: 0.1) == finals(step: 0.037))
        #expect(finals(step: 0.1) == finals(step: 1.3))
    }

    @Test func aLineThatStartsBeforeTheDelayEndsClosesThePreviousOne() {
        let lines: [ConversationScript.Line] = [
            .init(speaker: .me, start: 0, end: 1, text: "first part"),
            .init(speaker: .me, start: 1.1, end: 2, text: "second part"),
        ]
        var recognizer = ScriptRecognizer(lines: lines, finalDelay: 0.3)
        _ = recognizer.advance(to: 1.0)
        let events = recognizer.advance(to: 1.1)
        #expect(events.map(\.kind) == [.final, .interim])
        #expect(events.map(\.text) == ["first part", "second"])
    }

    @Test func finishFinalisesWhatWasHeardAndDropsWhatWasNot() {
        var recognizer = them()
        _ = recognizer.advance(to: 1.5)
        let events = recognizer.finish(at: 1.5)
        #expect(events == [SpeechEvent(kind: .final, text: "how are the", audioStart: 1.0, audioEnd: 1.5)])
    }

    @Test func streamFollowsTheAudioItIsSentAndEndsAfterFinish() async throws {
        let provider = ScriptedSpeechToText(script: Self.script)
        let stream = try await provider.openStream(for: .me)
        for chunk in Synth.silence(seconds: 2.8).chunks(of: 1_600, speaker: .me) {
            try await stream.send(chunk)
        }
        await stream.finish()
        // Sending after finish changes nothing.
        try await stream.send(AudioChunk(speaker: .me, samples: [0], capturedAt: .now))

        var events: [SpeechEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        #expect(events.map(\.kind) == [.interim, .interim, .final])
        #expect(events.last == SpeechEvent(kind: .final, text: "all good", audioStart: 2.5, audioEnd: 2.8))
        #expect(provider.displayName == "Scripted speech-to-text")
    }
}
