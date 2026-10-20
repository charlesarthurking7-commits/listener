/// Delays that double after every use, up to a ceiling: quick recovery from a blip
/// without hammering a device that is gone for good.
public struct Backoff: Sendable, Equatable {
    public let initial: Duration
    public let maximum: Duration
    private var current: Duration

    public init(initial: Duration, maximum: Duration) {
        self.initial = initial
        self.maximum = max(initial, maximum)
        current = initial
    }

    public mutating func next() -> Duration {
        defer { current = min(current * 2, maximum) }
        return current
    }

    public mutating func reset() {
        current = initial
    }
}

/// Spaces out the automatic restarts of a capture path.
///
/// A device change arrives as a burst of notifications, so the first restart after a
/// quiet spell waits a moment for the devices to settle. Restarts that follow each other
/// closely, because a device keeps failing or a restart itself causes another change,
/// back off instead of looping. The ceiling stays low because a pending retry also
/// decides how soon a newly plugged-in device gets picked up.
public struct RestartPacer: Sendable {
    public let settle: Duration
    public let quietPeriod: Duration
    private var backoff: Backoff
    private var lastRestart: ContinuousClock.Instant?

    public init(
        settle: Duration = .milliseconds(300),
        backoff: Backoff = Backoff(initial: .seconds(1), maximum: .seconds(5)),
        quietPeriod: Duration = .seconds(10)
    ) {
        self.settle = settle
        self.backoff = backoff
        self.quietPeriod = quietPeriod
    }

    /// How long to wait before the restart asked for at `now`.
    public mutating func delay(at now: ContinuousClock.Instant) -> Duration {
        guard let lastRestart, now - lastRestart < quietPeriod else {
            backoff.reset()
            return settle
        }
        return max(settle, backoff.next())
    }

    /// Records that a restart was attempted at `now`, whether or not it worked.
    public mutating func restarted(at now: ContinuousClock.Instant) {
        lastRestart = now
    }
}
