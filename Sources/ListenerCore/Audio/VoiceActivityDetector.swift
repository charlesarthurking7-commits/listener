import Foundation

/// A change in whether a channel carries speech. Times are seconds of that channel's
/// audio since its first sample.
public enum VoiceActivity: Sendable, Equatable {
    /// `at` is the start of the first loud frame of the burst.
    case speechStarted(at: Double)
    /// `at` is the end of the last loud frame, not the moment the silence was confirmed:
    /// this is where the latency clock starts.
    case speechEnded(at: Double)
}

/// Energy-based voice activity detection on 16 kHz mono audio in 20 ms frames.
///
/// Speech starts once the loud frames of a burst add up to `minSpeechMs`, so clicks and
/// short knocks never count, and is then reported from the first loud frame. It ends
/// after `hangoverMs` without a loud frame, which bridges the dips between words.
public struct VoiceActivityDetector: Sendable {
    public static let framesPerSecond = 50
    public static var frameDuration: Double { 1 / Double(framesPerSecond) }

    public let frameLength: Int
    public private(set) var isSpeaking = false

    private let thresholdSumOfSquares: Double
    private let minSpeechFrames: Int
    private let hangoverFrames: Int

    private var frameSumOfSquares: Int64 = 0
    private var frameFill = 0
    private var frameIndex = 0
    private var burstStart: Int?
    private var burstLoudFrames = 0
    private var lastLoudFrame = 0

    public init(
        thresholdDBFS: Double = -45,
        minSpeechMs: Int = 150,
        hangoverMs: Int = 200,
        sampleRate: Int = AudioChunk.sampleRate
    ) {
        frameLength = sampleRate / Self.framesPerSecond
        // Compare raw sums of squares so the per-frame check needs no log or division.
        let fullScale = 32768.0 * 32768.0
        thresholdSumOfSquares = pow(10, thresholdDBFS / 10) * fullScale * Double(frameLength)
        minSpeechFrames = max(1, Self.frames(milliseconds: minSpeechMs))
        hangoverFrames = max(1, Self.frames(milliseconds: hangoverMs))
    }

    public init(settings: TurnSettings) {
        self.init(thresholdDBFS: settings.vadThresholdDBFS, minSpeechMs: settings.minSpeechMs)
    }

    /// Seconds of audio analysed so far, in whole frames.
    public var position: Double { time(ofFrame: frameIndex) }

    /// Feeds the next samples of the channel, in any amount. Returns what changed, which
    /// is almost always nothing (and then allocates nothing).
    public mutating func process(_ samples: [Int16]) -> [VoiceActivity] {
        samples.withUnsafeBufferPointer { consume($0) }
    }

    public mutating func process(_ samples: ArraySlice<Int16>) -> [VoiceActivity] {
        samples.withUnsafeBufferPointer { consume($0) }
    }

    /// The channel has ended: closes speech that is still going.
    public mutating func finish() -> VoiceActivity? {
        burstStart = nil
        burstLoudFrames = 0
        guard isSpeaking else {
            return nil
        }
        isSpeaking = false
        return .speechEnded(at: time(ofFrame: lastLoudFrame + 1))
    }

    private mutating func consume(_ buffer: UnsafeBufferPointer<Int16>) -> [VoiceActivity] {
        var events: [VoiceActivity] = []
        var index = 0
        while index < buffer.count {
            let end = min(index + frameLength - frameFill, buffer.count)
            var sum = frameSumOfSquares
            for position in index..<end {
                let value = Int64(buffer[position])
                sum += value * value
            }
            frameSumOfSquares = sum
            frameFill += end - index
            index = end
            if frameFill == frameLength, let event = completeFrame() {
                events.append(event)
            }
        }
        return events
    }

    private mutating func completeFrame() -> VoiceActivity? {
        let loud = Double(frameSumOfSquares) > thresholdSumOfSquares
        let index = frameIndex
        frameIndex += 1
        frameSumOfSquares = 0
        frameFill = 0

        if loud {
            let start = burstStart ?? index
            if burstStart == nil {
                burstStart = index
                burstLoudFrames = 0
            }
            burstLoudFrames += 1
            lastLoudFrame = index
            if !isSpeaking && burstLoudFrames >= minSpeechFrames {
                isSpeaking = true
                return .speechStarted(at: time(ofFrame: start))
            }
            return nil
        }

        guard burstStart != nil, index - lastLoudFrame >= hangoverFrames else {
            return nil
        }
        burstStart = nil
        burstLoudFrames = 0
        guard isSpeaking else {
            return nil
        }
        isSpeaking = false
        return .speechEnded(at: time(ofFrame: lastLoudFrame + 1))
    }

    // Division keeps whole frame times exact: frame 33 is 0.66, not 0.66000000000000003.
    private func time(ofFrame index: Int) -> Double {
        Double(index) / Double(Self.framesPerSecond)
    }

    private static func frames(milliseconds: Int) -> Int {
        (milliseconds * framesPerSecond + 999) / 1000
    }
}
