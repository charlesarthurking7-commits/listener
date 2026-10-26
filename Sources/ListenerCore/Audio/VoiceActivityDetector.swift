import Foundation

/// A change in whether a channel carries speech. Times are seconds of that channel's
/// audio since its first sample.
public enum VoiceActivity: Sendable, Equatable {
    /// `at` is the start of the first loud frame of the stretch that confirmed the speech.
    case speechStarted(at: Double)
    /// `at` is the end of the speech's last loud frame, not the moment the silence was
    /// confirmed: this is where the latency clock starts.
    case speechEnded(at: Double)
}

/// Energy-based voice activity detection on 16 kHz mono audio in 20 ms frames.
///
/// A frame is loud above the threshold, and audible if it is at most 6 dB below it.
/// Speech starts once, within the last `minSpeechMs` and a quarter, `minSpeechMs` has
/// been audible and half of it loud, and is reported from the first loud frame there.
/// Counting audible frames keeps quiet speech, which wavers around the threshold, from
/// being missed. Keys and clicks are loud for a frame or two with near silence between
/// them, so however fast they come they never fill the stretch.
///
/// Speech ends after `hangoverMs` without a loud frame, which bridges the dips between
/// words. A loud frame only keeps speech going when at least half the stretch up to it
/// was audible, so typing that goes on after the speaker stops cannot hold it open:
/// speech also ends `hangoverMs` and a stretch after the last loud frame that did.
public struct VoiceActivityDetector: Sendable {
    public static let framesPerSecond = 50
    public static var frameDuration: Double { 1 / Double(framesPerSecond) }
    private static let audibleBelowThresholdDB = 6.0

    public let frameLength: Int
    public private(set) var isSpeaking = false

    private let thresholdSumOfSquares: Double
    private let audibleSumOfSquares: Double
    private let minSpeechFrames: Int
    private let windowFrames: Int
    private let windowMask: UInt64
    private let hangoverFrames: Int

    private var frameSumOfSquares: Int64 = 0
    private var frameFill = 0
    private var frameIndex = 0
    /// One bit per frame with the newest in bit 0, so bit n is the frame n frames back.
    private var loudFrames: UInt64 = 0
    private var audibleFrames: UInt64 = 0
    private var lastLoudFrame = 0
    /// The last loud frame with enough sound before it to keep speech going.
    private var lastSustainingFrame = 0

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
        audibleSumOfSquares = thresholdSumOfSquares * pow(10, -Self.audibleBelowThresholdDB / 10)
        let speechFrames = max(1, Self.frames(milliseconds: minSpeechMs))
        // The stretch has to fit in the frame masks, so a minimum over a second counts as about a second.
        windowFrames = min((speechFrames * 5 + 3) / 4, UInt64.bitWidth)
        windowMask = windowFrames == UInt64.bitWidth ? .max : (1 << windowFrames) - 1
        minSpeechFrames = min(speechFrames, windowFrames)
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

    /// The channel has ended: closes speech that is still going.
    public mutating func finish() -> VoiceActivity? {
        guard isSpeaking else {
            loudFrames = 0
            audibleFrames = 0
            return nil
        }
        return end(afterFrame: lastLoudFrame)
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
        let sumOfSquares = Double(frameSumOfSquares)
        let index = frameIndex
        frameIndex += 1
        frameSumOfSquares = 0
        frameFill = 0

        let loud = sumOfSquares > thresholdSumOfSquares
        loudFrames = loudFrames << 1 | (loud ? 1 : 0)
        audibleFrames = audibleFrames << 1 | (sumOfSquares > audibleSumOfSquares ? 1 : 0)
        let audibleInWindow = (audibleFrames & windowMask).nonzeroBitCount

        guard isSpeaking else {
            let loudInWindow = loudFrames & windowMask
            guard audibleInWindow >= minSpeechFrames, loudInWindow.nonzeroBitCount * 2 >= minSpeechFrames else {
                return nil
            }
            isSpeaking = true
            lastLoudFrame = index - loudInWindow.trailingZeroBitCount
            lastSustainingFrame = lastLoudFrame
            let firstLoudFrame = index - (UInt64.bitWidth - 1 - loudInWindow.leadingZeroBitCount)
            return .speechStarted(at: time(ofFrame: firstLoudFrame))
        }

        if loud {
            lastLoudFrame = index
            if audibleInWindow * 2 >= windowFrames {
                lastSustainingFrame = index
            }
        }
        if index - lastLoudFrame >= hangoverFrames {
            return end(afterFrame: lastLoudFrame)
        }
        if index - lastSustainingFrame >= hangoverFrames + windowFrames {
            return end(afterFrame: lastSustainingFrame)
        }
        return nil
    }

    /// Ends speech after `frame`. Starting again takes a whole new stretch of sound.
    private mutating func end(afterFrame frame: Int) -> VoiceActivity {
        isSpeaking = false
        loudFrames = 0
        audibleFrames = 0
        return .speechEnded(at: time(ofFrame: frame + 1))
    }

    // Division keeps whole frame times exact: frame 33 is 0.66, not 0.66000000000000003.
    private func time(ofFrame index: Int) -> Double {
        Double(index) / Double(Self.framesPerSecond)
    }

    private static func frames(milliseconds: Int) -> Int {
        (milliseconds * framesPerSecond + 999) / 1000
    }
}
