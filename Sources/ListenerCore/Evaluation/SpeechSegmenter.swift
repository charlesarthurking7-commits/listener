import Foundation

/// Cuts one channel's audio into the stretches a recognizer that hears whole utterances
/// would be given live. Listener's voice activity detector finds the speech, pauses
/// shorter than `joinGap` stay inside a segment as they do inside a turn, and no segment
/// runs past `maxLength`: a channel that never goes quiet is cut at its quietest moment
/// near the limit.
public struct SpeechSegmenter: Sendable {
    public var thresholdDBFS: Double
    public var minSpeechMs: Int
    /// Seconds of pause that end a segment.
    public var joinGap: Double
    public var maxLength: Double
    /// Seconds of audio kept either side of the speech, so word edges are not clipped.
    public var padding: Double

    public init(
        thresholdDBFS: Double = -45,
        minSpeechMs: Int = 150,
        joinGap: Double = 0.7,
        maxLength: Double = 30,
        padding: Double = 0.2
    ) {
        self.thresholdDBFS = thresholdDBFS
        self.minSpeechMs = minSpeechMs
        self.joinGap = joinGap
        self.maxLength = maxLength
        self.padding = padding
    }

    /// Speech and pauses as the live turn detector counts them.
    public init(settings: TurnSettings, maxLength: Double = 30) {
        self.init(
            thresholdDBFS: settings.vadThresholdDBFS,
            minSpeechMs: settings.minSpeechMs,
            joinGap: Double(settings.silenceMs) / 1000,
            maxLength: maxLength
        )
    }

    public func split(_ samples: [Int16], sampleRate: Int = AudioChunk.sampleRate) -> SpeechSegmentation {
        let duration = Double(samples.count) / Double(sampleRate)
        let levels = frameLevels(samples, sampleRate: sampleRate)
        let bursts = detectBursts(samples, sampleRate: sampleRate)
        let pieces = bursts.flatMap { cut($0, levels: levels) }

        var joined: [AudioSpan] = []
        for piece in pieces {
            if let last = joined.last, piece.start - last.end < joinGap, piece.end - last.start <= maxLength {
                joined[joined.count - 1] = AudioSpan(start: last.start, end: piece.end)
            } else {
                joined.append(piece)
            }
        }

        // Padding takes at most half of the gap to a neighbour, so segments never overlap.
        let segments = joined.indices.map { index in
            let span = joined[index]
            let before = index == 0 ? span.start : (span.start - joined[index - 1].end) / 2
            let after = index == joined.count - 1 ? duration - span.end : (joined[index + 1].start - span.end) / 2
            return AudioSpan(start: span.start - min(padding, before), end: span.end + min(padding, after))
        }

        let sorted = levels.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted.isEmpty ? LevelMeter.floorDBFS : sorted[Int(Double(sorted.count - 1) * fraction)]
        }
        return SpeechSegmentation(
            duration: duration,
            bursts: bursts,
            segments: segments,
            quietDBFS: percentile(0.1),
            medianDBFS: percentile(0.5),
            loudDBFS: percentile(0.9)
        )
    }

    private func detectBursts(_ samples: [Int16], sampleRate: Int) -> [AudioSpan] {
        var detector = VoiceActivityDetector(
            thresholdDBFS: thresholdDBFS, minSpeechMs: minSpeechMs, sampleRate: sampleRate)
        var events = detector.process(samples)
        if let end = detector.finish() {
            events.append(end)
        }
        var bursts: [AudioSpan] = []
        var start: Double?
        for event in events {
            switch event {
            case .speechStarted(let at):
                start = at
            case .speechEnded(let at):
                if let start {
                    bursts.append(AudioSpan(start: start, end: at))
                }
                start = nil
            }
        }
        return bursts
    }

    /// Splits a burst longer than `maxLength` at the quietest frame in the few seconds
    /// before each limit.
    private func cut(_ burst: AudioSpan, levels: [Double]) -> [AudioSpan] {
        let frame = VoiceActivityDetector.frameDuration
        let window = min(5, maxLength / 2)
        var pieces: [AudioSpan] = []
        var start = burst.start
        while burst.end - start > maxLength {
            let first = Int(((start + maxLength - window) / frame).rounded(.up))
            let last = min(Int((start + maxLength) / frame), levels.count) - 1
            var quietest = last
            for index in stride(from: last, through: first, by: -1) where levels[index] < levels[quietest] {
                quietest = index
            }
            let cutAt = quietest >= first ? Double(quietest) * frame : start + maxLength
            pieces.append(AudioSpan(start: start, end: cutAt))
            start = cutAt
        }
        pieces.append(AudioSpan(start: start, end: burst.end))
        return pieces
    }

    private func frameLevels(_ samples: [Int16], sampleRate: Int) -> [Double] {
        let length = sampleRate / VoiceActivityDetector.framesPerSecond
        return stride(from: 0, to: samples.count - length + 1, by: length).map { offset in
            LevelMeter.rmsDBFS(samples[offset..<offset + length])
        }
    }
}

/// A stretch of a recording, in seconds from its first sample.
public struct AudioSpan: Sendable, Equatable, Codable {
    public let start: Double
    public let end: Double

    public var duration: Double { end - start }
}

/// What the segmenter found in a recording.
public struct SpeechSegmentation: Sendable {
    public let duration: Double
    /// Speech as the voice activity detector heard it, before joining and cutting.
    public let bursts: [AudioSpan]
    public let segments: [AudioSpan]
    /// Levels of the recording's 20 ms frames at the 10th, 50th and 90th percentile, in
    /// dBFS. The 10th is the noise floor: when it is above the detector's threshold,
    /// the channel never sounds quiet and every pause is missed.
    public let quietDBFS: Double
    public let medianDBFS: Double
    public let loudDBFS: Double

    public var speechSeconds: Double { bursts.reduce(0) { $0 + $1.duration } }
    public var longestBurst: Double { bursts.map(\.duration).max() ?? 0 }
}
