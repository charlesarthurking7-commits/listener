import AppKit
import Carbon
import ListenerCore

/// Watches the fn (Globe) key in every app through a listen-only event tap, and reports
/// taps of it and presses of Escape. It only ever looks at fn, Escape, and whether some
/// other key went down; never at what is typed.
///
/// Seeing keys in other apps needs Accessibility permission. Until it is granted the
/// monitor checks every few seconds and starts as soon as it is, without a relaunch.
@MainActor
final class FnKeyMonitor {
    enum Signal: Equatable {
        case tap(FnTapDetector.Tap)
        case escape
    }

    private static let retryInterval: TimeInterval = 2

    private let onSignal: (Signal) -> Void
    /// Called once the monitor is watching, e.g. after permission was granted.
    var onStart: (() -> Void)?
    private var detector = FnTapDetector()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?

    init(onSignal: @escaping (Signal) -> Void) {
        self.onSignal = onSignal
    }

    var isRunning: Bool { tap != nil }

    /// Starts now if permitted, or as soon as permission is granted.
    func start() {
        guard tap == nil, !installTap() else {
            return
        }
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                if self.installTap() {
                    self.retry?.invalidate()
                    self.retry = nil
                }
            }
        }
    }

    /// The single tap just reported was used, so it cannot also start a double tap.
    func actedOnSingleTap() {
        detector.actedOnSingleTap()
    }

    private func installTap() -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }
        let events: [CGEventType] = [.flagsChanged, .keyDown]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        // The monitor lives as long as the app, so an unretained pointer is safe here.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: mask, callback: fnKeyEvent, userInfo: userInfo)
        else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        Log.dictation.info("Watching the fn key")
        onStart?()
        return true
    }

    fileprivate func handle(_ type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        case .flagsChanged:
            guard keyCode == kVK_Function else {
                _ = detector.handle(.otherKey, at: now)
                return
            }
            guard flags.contains(.maskSecondaryFn) else {
                if let tap = detector.handle(.fnUp, at: now) {
                    Log.dictation.debug("fn \(tap == .double ? "double tap" : "tap", privacy: .public)")
                    onSignal(.tap(tap))
                }
                return
            }
            _ = detector.handle(.fnDown, at: now)
            if !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty {
                _ = detector.handle(.otherKey, at: now)
            }
        case .keyDown:
            if let input = FnTapDetector.input(forKeyDown: Int(keyCode)) {
                _ = detector.handle(input, at: now)
            }
            if keyCode == kVK_Escape {
                onSignal(.escape)
            }
        default:
            break
        }
    }
}

/// The tap is on the main run loop, so this runs on the main thread.
private func fnKeyEvent(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        let (keyCode, flags) = (event.getIntegerValueField(.keyboardEventKeycode), event.flags)
        MainActor.assumeIsolated {
            monitor.handle(type, keyCode: keyCode, flags: flags)
        }
    }
    return Unmanaged.passUnretained(event)
}
