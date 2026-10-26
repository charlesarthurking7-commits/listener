import Foundation
import GRPCProtobuf
import ListenerCore

@testable import GoogleSpeech

extension ErrorDetails {
    /// What Google sends when the Speech-to-Text API is off in the project.
    static let serviceDisabled = ErrorDetails.errorInfo(
        reason: "SERVICE_DISABLED", domain: "googleapis.com",
        metadata: [
            "activationUrl":
                "https://console.developers.google.com/apis/api/speech.googleapis.com/overview?project=123",
            "consumer": "projects/123",
            "service": "speech.googleapis.com",
        ])
}

/// Builds responses the way Google shapes them: at most one final first, then interims.
enum Response {
    static func results(_ results: [(text: String, isFinal: Bool, end: Double?)]) -> RecognizeResponse {
        var response = RecognizeResponse()
        response.results = results.map { item in
            var result = Google_Cloud_Speech_V2_StreamingRecognitionResult()
            var alternative = Google_Cloud_Speech_V2_SpeechRecognitionAlternative()
            alternative.transcript = item.text
            result.alternatives = [alternative]
            result.isFinal = item.isFinal
            if let end = item.end {
                result.resultEndOffset.seconds = Int64(end)
                result.resultEndOffset.nanos = Int32(((end - end.rounded(.down)) * 1e9).rounded())
            }
            return result
        }
        return response
    }

    static func final(_ text: String, end: Double) -> RecognizeResponse {
        results([(text, true, end)])
    }

    static func interim(_ text: String, end: Double) -> RecognizeResponse {
        results([(text, false, end)])
    }

    static func speechBegin(at offset: Double) -> RecognizeResponse {
        speechEvent(.speechActivityBegin, at: offset)
    }

    static func speechEnd(at offset: Double) -> RecognizeResponse {
        speechEvent(.speechActivityEnd, at: offset)
    }

    private static func speechEvent(_ type: RecognizeResponse.SpeechEventType, at offset: Double) -> RecognizeResponse {
        var response = RecognizeResponse()
        response.speechEventType = type
        response.speechEventOffset.seconds = Int64(offset)
        response.speechEventOffset.nanos = Int32(((offset - offset.rounded(.down)) * 1e9).rounded())
        return response
    }
}

/// Audio whose every sample is its own position, so replayed audio can be checked
/// against the exact span it should cover.
enum Audio {
    static func samples(from start: Double, to end: Double) -> [Int16] {
        (position(start)..<position(end)).map { Int16(truncatingIfNeeded: $0) }
    }

    static func position(_ seconds: Double) -> Int {
        Int((seconds * Double(AudioChunk.sampleRate)).rounded())
    }

    /// Sends `[start, end)` seconds of the channel in 100 ms chunks.
    static func send(_ stream: any SpeechStream, from start: Double, to end: Double, chunk: Double = 0.1) async throws {
        var time = start
        while time < end - 1e-9 {
            let next = min(time + chunk, end)
            try await stream.send(AudioChunk(speaker: .them, samples: samples(from: time, to: next), capturedAt: .now))
            time = next
        }
    }
}

extension AsyncThrowingStream where Element == SpeechEvent {
    func collect() async throws -> [SpeechEvent] {
        var events: [SpeechEvent] = []
        for try await event in self {
            events.append(event)
        }
        return events
    }
}

extension SpeechEvent {
    static func final(_ text: String, _ start: Double, _ end: Double) -> SpeechEvent {
        SpeechEvent(kind: .final, text: text, audioStart: start, audioEnd: end)
    }

    static func interim(_ text: String, _ start: Double, _ end: Double) -> SpeechEvent {
        SpeechEvent(kind: .interim, text: text, audioStart: start, audioEnd: end)
    }
}
