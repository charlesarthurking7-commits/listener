/// The parts of the audio setup a system audio tap depends on. When any of them changes,
/// the tap has to be rebuilt to keep hearing the Mac at the right pitch.
public struct AudioRoute: Sendable, Equatable {
    public var outputDeviceUID: String?
    public var outputSampleRate: Double?
    public var captureSampleRate: Double?

    public init(outputDeviceUID: String?, outputSampleRate: Double?, captureSampleRate: Double?) {
        self.outputDeviceUID = outputDeviceUID
        self.outputSampleRate = outputSampleRate
        self.captureSampleRate = captureSampleRate
    }

    /// Why moving from this route to `current` needs a rebuild, or nil if it does not.
    /// A rate that cannot be read right now is not treated as a change: devices briefly
    /// refuse queries while they reconfigure, and a real change notifies again.
    public func restartReason(movingTo current: AudioRoute) -> CaptureRestartReason? {
        if current.outputDeviceUID != outputDeviceUID {
            return .outputDeviceChanged
        }
        if Self.differs(outputSampleRate, current.outputSampleRate)
            || Self.differs(captureSampleRate, current.captureSampleRate)
        {
            return .sampleRateChanged
        }
        return nil
    }

    private static func differs(_ old: Double?, _ new: Double?) -> Bool {
        guard let old, let new else {
            return false
        }
        return old != new
    }
}
