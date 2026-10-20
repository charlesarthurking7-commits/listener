/// Decides when to make an on-device recognizer finalize early.
///
/// Apple's SpeechTranscriber settles a phrase on its own schedule, typically 1 to 2
/// seconds after the speaker stops. Ending its session at a pause gets the final in
/// about 0.1 s instead. This watches the channel's level and fires once per stretch of
/// speech: when a pause follows it and the recognizer has not already settled that
/// speech by itself.
public struct FinalizationTrigger: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Audio at or above this level counts as speech.
        public var speechThresholdDBFS: Double
        /// Less speech than this before a pause is noise: a click, a keystroke.
        public var minSpeechSeconds: Double
        /// Silence after speech before the recognizer is made to finalize. Shorter gets
        /// finals sooner but splits more sentences where the speaker hesitates.
        public var pauseSeconds: Double

        public init(speechThresholdDBFS: Double = -45, minSpeechSeconds: Double = 0.15, pauseSeconds: Double = 0.4) {
            self.speechThresholdDBFS = speechThresholdDBFS
            self.minSpeechSeconds = minSpeechSeconds
            self.pauseSeconds = pauseSeconds
        }
    }

    public let configuration: Configuration
    private let sampleRate: Int
    private let windowSize: Int
    private let minSpeechSamples: Int
    private let pauseSamples: Int

    // Sample counts rather than seconds, so long calls do not accumulate rounding error.
    private var position = 0
    private var speechSamples = 0
    private var speechEnd = 0
    private var settledThrough = 0.0

    /// The level stays above the threshold a little after the last word ends (breath,
    /// room decay), so a recognizer that settled this close to the end counts as done.
    private let settledTolerance = 0.1

    public init(configuration: Configuration = Configuration(), sampleRate: Int = AudioChunk.sampleRate) {
        self.configuration = configuration
        self.sampleRate = sampleRate
        windowSize = max(sampleRate / 50, 1)
        minSpeechSamples = Int(configuration.minSpeechSeconds * Double(sampleRate))
        pauseSamples = Int(configuration.pauseSeconds * Double(sampleRate))
    }

    /// Feeds the channel's next chunk, measured in 20 ms windows. Returns true when the
    /// recognizer should finalize now.
    public mutating func process(_ samples: [Int16]) -> Bool {
        var fire = false
        var index = samples.startIndex
        while index < samples.endIndex {
            let next = min(index + windowSize, samples.endIndex)
            let window = samples[index..<next]
            position += window.count
            if LevelMeter.rmsDBFS(window) >= configuration.speechThresholdDBFS {
                speechSamples += window.count
                speechEnd = position
            } else if speechSamples > 0, position - speechEnd >= pauseSamples {
                let speechEndSeconds = Double(speechEnd) / Double(sampleRate)
                let unsettled = settledThrough < speechEndSeconds - settledTolerance
                if speechSamples >= minSpeechSamples, unsettled {
                    fire = true
                }
                speechSamples = 0
            }
            index = next
        }
        return fire
    }

    /// The recognizer settled everything before `time` (channel seconds) by itself.
    public mutating func recognizerSettled(through time: Double) {
        settledThrough = max(settledThrough, time)
    }
}
