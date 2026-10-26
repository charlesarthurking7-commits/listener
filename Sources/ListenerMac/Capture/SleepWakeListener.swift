import AppKit
import ListenerCore

/// Hears the Mac go to sleep and wake up again, until `remove()`.
///
/// Nothing in the audio path says the Mac slept: buffers just stop, and the devices can
/// come back in another state. So a capture source logs the sleep and rebuilds its
/// capture path on wake, as it would after a device change.
final class SleepWakeListener {
    private let observers: [any NSObjectProtocol]

    /// - Parameter onWake: runs on the main thread; hand work off to your own queue.
    init(speaker: Speaker, onWake: @escaping @Sendable () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
                Log.capture.notice("\(speaker.rawValue, privacy: .public): the Mac is going to sleep")
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
                onWake()
            },
        ]
    }

    /// Stops the notifications. Safe to call more than once.
    func remove() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
