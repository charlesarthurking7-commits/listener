/// Something a live capture source did on its own to keep audio flowing. The channel
/// never stops because of these: while a source recovers, its gap arrives as silence.
public enum CaptureEvent: Sendable, Equatable, CustomStringConvertible {
    /// The source tore down its capture path and built a new one.
    case restarted(Speaker, reason: CaptureRestartReason)
    /// Rebuilding failed; the source tries again after `retryIn`.
    case restartFailed(Speaker, reason: CaptureRestartReason, error: String, retryIn: Duration)
    /// Voice processing would not start with the current devices, so the mic runs without it.
    case voiceProcessingUnavailable(error: String)
    /// The user ended the capture from outside the app (for example "Stop Sharing" in the
    /// menu bar). The channel stays silent until the next Start.
    case stoppedByUser(Speaker)
    /// Audio arrives at another sample rate than the one it was read at, so the source
    /// reads it at the rate it arrives at from now on (see DeliveredRateMonitor).
    case rateCorrected(Speaker, from: Double, to: Double)

    public var description: String {
        switch self {
        case .restarted(let speaker, let reason):
            "\(speaker.rawValue): capture restarted (\(reason))."
        case .restartFailed(let speaker, let reason, let error, let retryIn):
            "\(speaker.rawValue): capture restart after \(reason) failed: \(error). "
                + "Retrying in \(Self.seconds(retryIn)) s, sending silence meanwhile."
        case .voiceProcessingUnavailable(let error):
            "Me: echo cancellation is unavailable with the current audio devices (\(error)), "
                + "so the mic runs without it."
        case .stoppedByUser(let speaker):
            "\(speaker.rawValue): capture was stopped from outside Listener."
        case .rateCorrected(let speaker, let from, let to):
            "\(speaker.rawValue): audio arrives at \(Self.kHz(to)), not \(Self.kHz(from)), so Listener now reads it "
                + "at \(Self.kHz(to))."
        }
    }

    /// "24 kHz", "44.1 kHz", "11.025 kHz".
    static func kHz(_ rate: Double) -> String {
        let hertz = Int(rate.rounded())
        guard hertz % 1000 != 0 else {
            return "\(hertz / 1000) kHz"
        }
        var fraction = String(hertz % 1000)
        fraction = String(repeating: "0", count: 3 - fraction.count) + fraction
        while fraction.hasSuffix("0") {
            fraction.removeLast()
        }
        return "\(hertz / 1000).\(fraction) kHz"
    }

    private static func seconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        let tenths = attoseconds / 100_000_000_000_000_000
        return tenths == 0 ? "\(seconds)" : "\(seconds).\(tenths)"
    }
}

public enum CaptureRestartReason: Sendable, Equatable, CustomStringConvertible {
    case outputDeviceChanged
    case inputDeviceChanged
    case sampleRateChanged
    /// AVAudioEngine stopped itself because the hardware format changed.
    case audioConfigurationChanged
    /// Exact digital silence for this long while another app had audio output running.
    case digitalSilence(seconds: Int)
    /// The capture stream ended with an error.
    case streamStopped
    case wokeFromSleep

    public var description: String {
        switch self {
        case .outputDeviceChanged: "output device changed"
        case .inputDeviceChanged: "input device changed"
        case .sampleRateChanged: "sample rate changed"
        case .audioConfigurationChanged: "audio configuration changed"
        case .digitalSilence(let seconds): "\(seconds) s of digital silence while another app was playing audio"
        case .streamStopped: "stream stopped"
        case .wokeFromSleep: "Mac woke from sleep"
        }
    }
}
