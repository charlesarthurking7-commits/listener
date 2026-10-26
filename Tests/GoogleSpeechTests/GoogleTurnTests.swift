import Foundation
import ListenerCore
import Testing

@testable import GoogleSpeech

/// Google's results on both channels, with the voice activity a call would have,
/// through turn detection to the transcript the model reads.
struct GoogleTurnTests {
    @Test func aNoiseLongBeforeAnAnswerDoesNotPutItAheadOfTheQuestion() {
        // Them coughs at 15 s, Me asks something at 20 s and Them answers at 30 s.
        // Google's voice activity hears the cough too, but no words come of it.
        var call = GoogleCall()
        call.speak(.them, from: 8.0, to: 10.0)
        call.respond(.them, at: 8.3, Response.speechBegin(at: 8.0))
        call.respond(.them, at: 9.0, Response.interim("earlier", end: 9.0))
        call.respond(.them, at: 10.4, Response.speechEnd(at: 10.1))
        call.respond(.them, at: 10.6, Response.final("Earlier point.", end: 10.3))

        call.speak(.them, from: 15.0, to: 15.3)
        call.respond(.them, at: 15.3, Response.speechBegin(at: 15.0))
        call.respond(.them, at: 15.7, Response.speechEnd(at: 15.4))

        call.speak(.me, from: 20.0, to: 22.0)
        call.respond(.me, at: 20.3, Response.speechBegin(at: 20.0))
        call.respond(.me, at: 21.0, Response.interim("sorry can you", end: 21.0))
        call.respond(.me, at: 22.4, Response.speechEnd(at: 22.1))
        call.respond(.me, at: 22.6, Response.final("Sorry, can you repeat that?", end: 22.3))

        call.speak(.them, from: 30.0, to: 33.0)
        call.respond(.them, at: 30.3, Response.speechBegin(at: 30.0))
        call.respond(.them, at: 31.0, Response.interim("yes the trade", end: 31.0))
        call.respond(.them, at: 33.4, Response.speechEnd(at: 33.1))
        call.respond(.them, at: 33.6, Response.final("Yes, the trade settles T plus two.", end: 33.3))

        call.play(to: 36)
        #expect(
            call.transcript == """
                [00:08-00:10] Them: Earlier point.
                [00:20-00:22] Me: Sorry, can you repeat that?
                [00:30-00:33] Them: Yes, the trade settles T plus two.

                """)
    }
}

/// Both channels of a call recognised by Google, played in real time. Speech is a tone
/// the voice activity detector hears, and each response arrives once the audio it
/// describes has been sent.
private struct GoogleCall {
    private struct Channel {
        var timeline = ChannelTimeline(replayLimit: Audio.position(30), utterancePause: Audio.position(0.7))
        var voice = VoiceActivityDetector()
        var speech: [Range<Double>] = []
        var responses: [(at: Double, response: RecognizeResponse)] = []
    }

    private var detector = TurnDetector(settings: TurnSettings())
    private var channels: [Speaker: Channel] = [.me: Channel(), .them: Channel()]

    var transcript: String {
        TranscriptWindow(turns: detector.snapshot.turns, budgetTokens: 8_000, hardCapTokens: 60_000).blocks.joined()
    }

    mutating func speak(_ speaker: Speaker, from start: Double, to end: Double) {
        channels[speaker]?.speech.append(start..<end)
    }

    /// Responses for a channel must be added in the order they arrive.
    mutating func respond(_ speaker: Speaker, at time: Double, _ response: RecognizeResponse) {
        channels[speaker]?.responses.append((time, response))
    }

    /// Both channels in 100 ms frames, as capture delivers them.
    mutating func play(to end: Double) {
        for tenth in 0..<Int((end * 10).rounded()) {
            let frame = Double(tenth) / 10..<Double(tenth + 1) / 10
            step(.me, over: frame)
            step(.them, over: frame)
        }
    }

    private mutating func step(_ speaker: Speaker, over frame: Range<Double>) {
        guard var channel = channels[speaker] else {
            return
        }
        let samples = (Audio.position(frame.lowerBound)..<Audio.position(frame.upperBound)).map { index in
            let time = Double(index) / Double(AudioChunk.sampleRate)
            return channel.speech.contains { $0.contains(time) } ? Int16(3_000 * sin(2 * .pi * 440 * time)) : 0
        }
        channel.timeline.append(samples)
        let activity = channel.voice.process(samples)
        _ = detector.audioProgress(speaker, frame: frame, capturedAt: frame.upperBound, activity: activity)
        while let next = channel.responses.first, next.at < frame.upperBound + 1e-9 {
            channel.responses.removeFirst()
            for event in channel.timeline.events(for: next.response) {
                _ = detector.speechEvent(event, speaker: speaker)
            }
        }
        channels[speaker] = channel
    }
}
