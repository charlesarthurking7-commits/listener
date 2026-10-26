/// Notices when a capture path has quietly died.
///
/// A Core Audio process tap without the System Audio Recording permission does not fail:
/// it keeps delivering buffers of exact zeros. Some taps on macOS 26 go the same way in
/// the middle of a session, and only rebuilding them brings the audio back. Real audio,
/// even near-silence, is almost never exactly zero, so a long run of digital zeros is the
/// signal to rebuild.
///
/// Feed it the delivered stream, including any silence filled in for gaps, so a source
/// that stopped delivering altogether is caught too. When a rebuild does not help, the
/// next one waits twice as long, up to `maximumTimeout`; any real audio resets that.
///
/// Once a path has delivered real audio, zeros are far more often a call where everyone
/// else is muted than a path that died, and a rebuild costs a moment of audio, so then
/// it waits at least `heardTimeout`.
public struct SilenceWatchdog: Sendable {
    public let baseTimeout: Duration
    public let maximumTimeout: Duration
    public static let heardTimeout = Duration.seconds(60)
    /// How much unbroken digital silence it currently takes to ask for a rebuild.
    public private(set) var timeout: Duration
    /// Digital silence since the last real audio, rebuild or explained silence.
    public private(set) var silence: Duration = .zero
    /// A rebuild has been asked for and not yet reported back.
    public private(set) var isDue = false
    /// Real audio has come through since the path was built.
    private var hasHeardAudio = false

    public init(timeout: Duration = .seconds(10), maximumTimeout: Duration = .seconds(320)) {
        baseTimeout = timeout
        self.maximumTimeout = max(timeout, maximumTimeout)
        self.timeout = timeout
    }

    /// Records one delivered chunk. Returns true exactly when the silence first reaches
    /// the timeout; it then stays quiet until `rebuilt()` or `silenceExplained()`.
    public mutating func observe(_ chunk: AudioChunk) -> Bool {
        if !LevelMeter.isDigitalSilence(chunk.samples) {
            silence = .zero
            timeout = baseTimeout
            isDue = false
            hasHeardAudio = true
            return false
        }
        silence += SampleClock.duration(ofSamples: chunk.samples.count)
        if isDue || silence < (hasHeardAudio ? max(timeout, Self.heardTimeout) : timeout) {
            return false
        }
        isDue = true
        return true
    }

    /// The capture path was rebuilt. If the silence carries on, wait twice as long before
    /// asking again.
    public mutating func rebuilt() {
        silence = .zero
        isDue = false
        hasHeardAudio = false
        timeout = min(timeout * 2, maximumTimeout)
    }

    /// The silence has an innocent cause, such as nothing playing on the Mac. Start
    /// counting again without backing off.
    public mutating func silenceExplained() {
        silence = .zero
        isDue = false
    }
}
