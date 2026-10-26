import Foundation
import IOKit
import ListenerCore

/// Shared plumbing for the capture sources.
enum CaptureSupport {
    /// For sources that deliver silence themselves (the tap's IO proc, the mic engine),
    /// filling is only needed when they fail, so wait longer before deciding a buffer is
    /// missing rather than late: silence inserted into speech hurts recognition.
    static let deviceGapThreshold: Duration = .milliseconds(500)

    /// Whether a laptop's lid is shut, which cuts off its built-in microphone.
    static var isLidClosed: Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else {
            return false
        }
        defer { IOObjectRelease(rootDomain) }
        let state = IORegistryEntryCreateCFProperty(
            rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
    }

    /// Logs the event and passes it on to whoever asked to hear about it.
    static func report(_ event: CaptureEvent, to handler: (@Sendable (CaptureEvent) -> Void)?) {
        Log.capture.notice("\(event.description, privacy: .public)")
        handler?(event)
    }

    static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
