/// Caps how often the window redraws from session events. The first change after a
/// quiet spell is drawn at once, so an answer's first word is never held back; changes
/// that follow within `interval` are coalesced into one redraw at the end of it.
public struct UpdateThrottle: Sendable {
    public enum Decision: Sendable, Equatable {
        case now
        /// Redraw after this many seconds, then call `didUpdate(at:)`.
        case after(Double)
        /// A redraw is already scheduled and will include this change.
        case alreadyScheduled
    }

    /// About one display frame.
    public static let displayRate = UpdateThrottle(interval: 1.0 / 60)

    public let interval: Double
    private var lastUpdate: Double?
    private var scheduled = false

    public init(interval: Double) {
        self.interval = interval
    }

    /// Something changed at `now` (seconds on any monotonic clock).
    public mutating func request(at now: Double) -> Decision {
        if scheduled {
            return .alreadyScheduled
        }
        if let lastUpdate, now - lastUpdate < interval {
            scheduled = true
            return .after(interval - (now - lastUpdate))
        }
        lastUpdate = now
        return .now
    }

    /// The window redrew at `now`, either for a scheduled update or for a change the
    /// user made directly.
    public mutating func didUpdate(at now: Double) {
        lastUpdate = now
        scheduled = false
    }
}
