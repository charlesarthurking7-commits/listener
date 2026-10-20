import CoreAudio
import Synchronization

/// Calls a handler when a Core Audio property changes, until `remove()`.
///
/// Uses the function-pointer listener API rather than the block one: Core Audio removes
/// a block listener only when handed the identical block object, which a Swift closure
/// does not guarantee. The client data is a plain number looked up in a table, not an
/// object pointer, so a notification that races with removal finds nothing to call
/// instead of touching freed memory.
final class PropertyListener: Sendable {
    private static let handlers = Mutex<(next: Int, byToken: [Int: @Sendable () -> Void])>((1, [:]))

    private static let callback: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        let token = Int(bitPattern: clientData)
        let handler = PropertyListener.handlers.withLock { $0.byToken[token] }
        handler?()
        return noErr
    }

    private let object: AudioObjectID
    private let selector: AudioObjectPropertySelector
    private let token: Int

    /// - Parameter handler: runs on a Core Audio notification thread; hand work off to your own queue.
    init(object: AudioObjectID, selector: AudioObjectPropertySelector, handler: @escaping @Sendable () -> Void) throws {
        self.object = object
        self.selector = selector
        token = Self.handlers.withLock { table in
            defer { table.next += 1 }
            table.byToken[table.next] = handler
            return table.next
        }
        var address = CoreAudioObjects.globalAddress(selector)
        let status = AudioObjectAddPropertyListener(
            object, &address, Self.callback, UnsafeMutableRawPointer(bitPattern: token))
        if status != noErr {
            _ = Self.handlers.withLock { $0.byToken.removeValue(forKey: token) }
            let property = fourCharacterCode(Int32(bitPattern: selector))
            throw CaptureError.coreAudio(operation: "Listen for audio property \(property)", status: status)
        }
    }

    /// Stops the notifications. Safe to call more than once.
    func remove() {
        let registered = Self.handlers.withLock { $0.byToken.removeValue(forKey: token) } != nil
        if registered {
            var address = CoreAudioObjects.globalAddress(selector)
            AudioObjectRemovePropertyListener(
                object, &address, Self.callback, UnsafeMutableRawPointer(bitPattern: token))
        }
    }
}
