/// Speech-to-text that "recognises" a ConversationScript instead of audio, for replay
/// without network access, demos and tests.
///
/// Each stream only follows the audio it has been sent, by sample count, so it behaves
/// the same at any replay speed. While a line of its speaker is being spoken it sends
/// interim text that grows word by word; `finalDelay` seconds of audio after the line
/// ends it sends the final, with the line's times as audioStart and audioEnd.
///
/// Script times are taken as positions in the audio the stream receives, so this
/// assumes every sample is sent, i.e. silence skipping is off.
public struct ScriptedSpeechToText: SpeechToTextProvider {
    public let script: ConversationScript
    public let finalDelay: Double

    public init(script: ConversationScript, finalDelay: Double = 0.3) {
        self.script = script
        self.finalDelay = finalDelay
    }

    public var displayName: String { "Scripted speech-to-text" }

    public func openStream(for speaker: Speaker) async throws -> any SpeechStream {
        let lines = script.lines.filter { $0.speaker == speaker }.sorted { $0.start < $1.start }
        return ScriptedSpeechStream(lines: lines, finalDelay: finalDelay)
    }
}

public actor ScriptedSpeechStream: SpeechStream {
    public nonisolated let events: AsyncThrowingStream<SpeechEvent, any Error>
    private let continuation: AsyncThrowingStream<SpeechEvent, any Error>.Continuation
    private var recognizer: ScriptRecognizer
    private var sampleCount = 0
    private var finished = false

    /// `lines` must be one speaker's, sorted by start.
    public init(lines: [ConversationScript.Line], finalDelay: Double) {
        (events, continuation) = AsyncThrowingStream.makeStream(of: SpeechEvent.self)
        recognizer = ScriptRecognizer(lines: lines, finalDelay: finalDelay)
    }

    /// Seconds of audio received so far.
    public var position: Double { Double(sampleCount) / Double(AudioChunk.sampleRate) }

    public func send(_ chunk: AudioChunk) async throws {
        guard !finished else {
            return
        }
        sampleCount += chunk.samples.count
        for event in recognizer.advance(to: position) {
            continuation.yield(event)
        }
    }

    /// Finalises whatever has been heard of lines still going, then ends `events`.
    public func finish() async {
        guard !finished else {
            return
        }
        finished = true
        for event in recognizer.finish(at: position) {
            continuation.yield(event)
        }
        continuation.finish()
    }
}

/// The script-following logic behind ScriptedSpeechStream, driven by audio position.
struct ScriptRecognizer {
    private let lines: [ConversationScript.Line]
    private let finalDelay: Double
    /// The first line that has not had its final yet.
    private var current = 0
    private var lastInterim: String?

    init(lines: [ConversationScript.Line], finalDelay: Double) {
        self.lines = lines
        self.finalDelay = finalDelay
    }

    mutating func advance(to position: Double) -> [SpeechEvent] {
        var events: [SpeechEvent] = []
        while current < lines.count {
            let line = lines[current]
            // A real recogniser closes an utterance before the next one begins, so a
            // line followed closely by the next is finalised early.
            let nextStarted = current + 1 < lines.count && position >= lines[current + 1].start
            if position >= line.end + finalDelay || nextStarted {
                events.append(SpeechEvent(kind: .final, text: line.text, audioStart: line.start, audioEnd: line.end))
                current += 1
                lastInterim = nil
                continue
            }
            let heard = Self.heardText(of: line, at: position)
            if !heard.isEmpty && heard != lastInterim {
                lastInterim = heard
                events.append(SpeechEvent(kind: .interim, text: heard))
            }
            break
        }
        return events
    }

    /// The audio has ended at `position`: finals for every line that had begun, with
    /// the words heard so far.
    mutating func finish(at position: Double) -> [SpeechEvent] {
        var events = advance(to: position)
        while current < lines.count, position >= lines[current].start {
            let line = lines[current]
            let heard = Self.heardText(of: line, at: position)
            if !heard.isEmpty {
                let end = min(line.end, position)
                events.append(SpeechEvent(kind: .final, text: heard, audioStart: line.start, audioEnd: end))
            }
            current += 1
        }
        return events
    }

    /// The words of `line` spoken by `position`, taking them as evenly spread over it.
    private static func heardText(of line: ConversationScript.Line, at position: Double) -> String {
        let words = line.text.split(whereSeparator: \.isWhitespace)
        guard position >= line.start, !words.isEmpty else {
            return ""
        }
        if position >= line.end {
            return line.text
        }
        let fraction = (position - line.start) / (line.end - line.start)
        let count = min(words.count, max(1, Int((fraction * Double(words.count)).rounded(.up))))
        return words[..<count].joined(separator: " ")
    }
}
