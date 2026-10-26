import Carbon
import ListenerCore

struct HotkeyRegistrationFailure: Sendable {
    let action: HotkeyAction
    let message: String
}

/// Global hotkeys through Carbon's RegisterEventHotKey. Unlike event taps and global
/// NSEvent monitors it needs no Accessibility or Input Monitoring permission.
///
/// Hotkeys are registered as exclusive, so a combination another app holds
/// exclusively fails with eventHotKeyExistsErr instead of firing in both apps.
@MainActor
final class HotkeyCenter {
    /// "LSTN", tags our hotkey IDs.
    private static let signature: OSType = 0x4C53_544E

    /// The action and when its key went down.
    private let onPress: (HotkeyAction, ContinuousClock.Instant) -> Void
    private var registered: [UInt32: (action: HotkeyAction, ref: EventHotKeyRef)] = [:]
    private var eventHandler: EventHandlerRef?

    init(onPress: @escaping (HotkeyAction, ContinuousClock.Instant) -> Void) {
        self.onPress = onPress
    }

    /// Replaces any earlier registrations. Returns the hotkeys that could not be registered.
    func register(_ hotkeys: [HotkeyAction: Hotkey]) -> [HotkeyRegistrationFailure] {
        unregisterAll()
        let handlerStatus = installEventHandler()
        var failures: [HotkeyRegistrationFailure] = []
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let hotkey = hotkeys[action] else {
                continue
            }
            if handlerStatus != noErr {
                failures.append(failure(action, hotkey, status: handlerStatus))
                continue
            }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(hotkey.key.keyCode),
                Self.carbonModifiers(hotkey.modifiers),
                EventHotKeyID(signature: Self.signature, id: id),
                GetEventDispatcherTarget(),
                OptionBits(kEventHotKeyExclusive),
                &ref
            )
            if status == noErr, let ref {
                registered[id] = (action, ref)
            } else {
                failures.append(failure(action, hotkey, status: status))
            }
        }
        return failures
    }

    private func unregisterAll() {
        for entry in registered.values {
            UnregisterEventHotKey(entry.ref)
        }
        registered = [:]
    }

    fileprivate func handlePress(id: UInt32, at pressedAt: ContinuousClock.Instant) {
        if let action = registered[id]?.action {
            onPress(action, pressedAt)
        }
    }

    private func installEventHandler() -> OSStatus {
        if eventHandler != nil {
            return noErr
        }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The center lives as long as the app, so an unretained pointer is safe here.
        let userData = Unmanaged.passUnretained(self).toOpaque()
        return InstallEventHandler(GetEventDispatcherTarget(), hotkeyPressed, 1, &pressed, userData, &eventHandler)
    }

    private func failure(_ action: HotkeyAction, _ hotkey: Hotkey, status: OSStatus) -> HotkeyRegistrationFailure {
        let message =
            if status == eventHotKeyExistsErr {
                "\(hotkey.displayString) for \(action.title.lowercased()) is taken by another app. "
                    + "Choose another in \(action.settingKey)."
            } else {
                "\(hotkey.displayString) for \(action.title.lowercased()) could not be registered (error \(status))."
            }
        return HotkeyRegistrationFailure(action: action, message: message)
    }

    static func carbonModifiers(_ modifiers: HotkeyModifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.control) {
            flags |= UInt32(controlKey)
        }
        if modifiers.contains(.option) {
            flags |= UInt32(optionKey)
        }
        if modifiers.contains(.shift) {
            flags |= UInt32(shiftKey)
        }
        if modifiers.contains(.command) {
            flags |= UInt32(cmdKey)
        }
        return flags
    }
}

/// Carbon calls this on the main thread, from the application's event loop.
private func hotkeyPressed(
    _ callRef: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }
    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )
    guard status == noErr else {
        return status
    }
    // The event can wait behind other work on the main thread; that wait is part of
    // the answer's latency, so the press is timed from the event itself.
    let waited = min(max(ProcessInfo.processInfo.systemUptime - GetEventTime(event), 0), 2)
    let pressedAt = ContinuousClock.now - .seconds(waited)
    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    let id = hotkeyID.id
    MainActor.assumeIsolated {
        center.handlePress(id: id, at: pressedAt)
    }
    return noErr
}
