import Foundation
import ListenerCore
import SwiftProtobuf

/// One channel's audio as it passes through a series of Google streams: which samples
/// have settled into finals, which a new stream has to hear again, and how each
/// stream's offsets map back to the channel. Pure bookkeeping; the stream actor does
/// the I/O. Positions are sample indexes from the channel's first chunk.
struct ChannelTimeline {
    static let sampleRate = AudioChunk.sampleRate

    /// Never keep more than this for replay. Only reached when nothing has been
    /// finalised for a long time, which in practice means silence.
    let replayLimit: Int
    /// A pause in Google's voice activity shorter than this does not split the speech
    /// around it, just as it would not end a turn.
    let utterancePause: Int

    private(set) var received = 0
    /// End of the last final. Everything before it is settled.
    private(set) var settledEnd = 0
    /// Channel position of offset zero in the current stream.
    private(set) var streamStart = 0
    /// The guess on screen for the utterance in progress, if any.
    private var interim: SpeechEvent?

    /// Unsettled audio lives in `buffer[head...]`, starting at channel position
    /// `unsettledStart`. Dropping from the front only moves `head`; the array is
    /// compacted once the dead part outgrows the live one.
    private var buffer: [Int16] = []
    private var head = 0
    private(set) var unsettledStart = 0
    /// Where Google heard speech begin and end (voice activity events) since the last
    /// final. The end is nil while the speech goes on.
    private var activity: [(start: Int, end: Int?)] = []
    /// The end of the first interim with words since the last final: the utterance
    /// had begun by then.
    private var firstWordsBy: Int?

    init(replayLimit: Int, utterancePause: Int) {
        self.replayLimit = replayLimit
        self.utterancePause = utterancePause
    }

    var unsettled: ArraySlice<Int16> { buffer[head...] }
    var hasUnsettledAudio: Bool { head < buffer.count }

    /// True when Google has shown no sign of speech since the last final, so the
    /// unsettled audio is most likely silence.
    var isIdle: Bool { interim == nil && activity.isEmpty }

    mutating func append(_ samples: [Int16]) {
        received += samples.count
        buffer.append(contentsOf: samples)
        let excess = buffer.count - head - replayLimit
        if excess > 0 {
            dropUnsettled(excess)
        }
    }

    /// Keeps only the newest `count` unsettled samples. Used when a stream has to be
    /// replaced while idle, so a long silence is not sent again.
    mutating func keepNewest(_ count: Int) {
        let excess = buffer.count - head - count
        if excess > 0 {
            dropUnsettled(excess)
        }
    }

    /// Starts a new stream at the oldest unsettled sample and returns the audio it
    /// must hear first.
    mutating func beginStream() -> ArraySlice<Int16> {
        streamStart = unsettledStart
        return unsettled
    }

    /// Turns one response from the current stream into events, in order: at most
    /// one final, then the interim for whatever follows it.
    mutating func events(for response: Google_Cloud_Speech_V2_StreamingRecognizeResponse) -> [SpeechEvent] {
        if response.hasSpeechEventOffset {
            let offset = position(of: response.speechEventOffset)
            switch response.speechEventType {
            case .speechActivityBegin:
                activity.append((offset, nil))
                return []
            case .speechActivityEnd:
                if let last = activity.indices.last, activity[last].end == nil {
                    activity[last].end = max(offset, activity[last].start)
                }
                return []
            default:
                break
            }
        }

        var events: [SpeechEvent] = []
        var interimTexts: [String] = []
        var interimEnd: Int?
        for result in response.results {
            let text = result.alternatives.first?.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let end = result.hasResultEndOffset ? position(of: result.resultEndOffset) : nil
            if result.isFinal {
                events += settle(text: text, end: end)
            } else if !text.isEmpty {
                interimTexts.append(text)
                if let end {
                    interimEnd = max(interimEnd ?? end, end)
                }
            }
        }

        if !interimTexts.isEmpty {
            let end = interimEnd ?? received
            firstWordsBy = firstWordsBy ?? end
            let event = SpeechEvent(
                kind: .interim,
                text: interimTexts.joined(separator: " "),
                audioStart: seconds(utteranceStart(before: end)),
                audioEnd: seconds(end))
            events.append(event)
            interim = event
        }
        return events
    }

    /// Gives up on the unsettled audio after Google hung up for lack of audio: it
    /// will not finalise what it heard, so the guess on screen becomes the final.
    mutating func abandonUnsettled() -> [SpeechEvent] {
        var events: [SpeechEvent] = []
        if var last = interim {
            last.kind = .final
            events.append(last)
            if let end = last.audioEnd {
                settledEnd = max(settledEnd, Int((end * Double(Self.sampleRate)).rounded()))
            }
        }
        interim = nil
        firstWordsBy = nil
        activity.removeAll()
        dropUnsettled(buffer.count - head)
        return events
    }

    private mutating func settle(text: String, end: Int?) -> [SpeechEvent] {
        let start = utteranceStart(before: end ?? received)
        if let end {
            if end > unsettledStart {
                dropUnsettled(min(end - unsettledStart, buffer.count - head))
            }
            settledEnd = max(settledEnd, end)
            activity.removeAll { $0.start < end }
        }

        let wasShowing = interim != nil
        interim = nil
        firstWordsBy = nil
        if text.isEmpty {
            // Google sometimes settles noise into an empty final. An empty interim
            // clears whatever guess was on screen for it.
            return wasShowing ? [SpeechEvent(kind: .interim, text: "")] : []
        }
        return [SpeechEvent(kind: .final, text: text, audioStart: seconds(start), audioEnd: end.map(seconds))]
    }

    /// Without word timings (Chirp 3 has none when streaming), the start comes from
    /// Google's voice activity: the start of the last stretch of it, short pauses
    /// included, to begin before the first words showed (or before the final, if it
    /// came without an interim). Without voice activity, the end of the previous final.
    ///
    /// The first activity since the previous final could be a cough long before the
    /// words, which would put them ahead of whatever the other side said in between.
    private func utteranceStart(before end: Int) -> Int {
        let wordsBy = min(firstWordsBy ?? end, end)
        var start: Int?
        var previousEnd: Int?
        for run in activity where run.start >= settledEnd && run.start < wordsBy {
            if let previousEnd, run.start - previousEnd >= utterancePause {
                start = nil
            }
            start = start ?? run.start
            previousEnd = run.end
        }
        return start ?? min(max(settledEnd, streamStart), end)
    }

    private mutating func dropUnsettled(_ count: Int) {
        head += count
        unsettledStart += count
        if head > buffer.count / 2 && head >= Self.sampleRate {
            buffer.removeFirst(head)
            head = 0
        }
    }

    private func position(of offset: Google_Protobuf_Duration) -> Int {
        let samples =
            offset.seconds * Int64(Self.sampleRate) + Int64(offset.nanos) * Int64(Self.sampleRate) / 1_000_000_000
        return min(max(streamStart + Int(samples), streamStart), received)
    }

    private func seconds(_ position: Int) -> Double {
        Double(position) / Double(Self.sampleRate)
    }
}
