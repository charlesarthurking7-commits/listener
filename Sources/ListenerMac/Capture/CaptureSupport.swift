import Foundation
import ListenerCore
import os

/// Shared plumbing for the capture sources.
enum CaptureSupport {
    static let logger = Logger(subsystem: "local.listener", category: "capture")

    /// For sources that deliver silence themselves (the tap's IO proc, the mic engine),
    /// filling is only needed when they fail, so wait longer before deciding a buffer is
    /// missing rather than late: silence inserted into speech hurts recognition.
    static let deviceGapThreshold: Duration = .milliseconds(500)

    /// Logs the event and passes it on to whoever asked to hear about it.
    static func report(_ event: CaptureEvent, to handler: (@Sendable (CaptureEvent) -> Void)?) {
        logger.notice("\(event.description, privacy: .public)")
        handler?(event)
    }

    static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
