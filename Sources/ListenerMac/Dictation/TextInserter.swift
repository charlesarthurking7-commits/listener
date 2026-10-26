import AppKit
import Carbon
import ListenerCore

/// Types text into the app in front by pasting it: the text goes on the clipboard,
/// Command-V is posted, and the clipboard is put back as it was. Pasting works in every
/// app, native or not, where typing key by key is slow and trips over keyboard layouts.
@MainActor
enum TextInserter {
    enum Outcome: Equatable {
        case pasted
        /// Left on the clipboard instead, for the user to paste.
        case copied
    }

    /// Clipboard managers leave items with this type out of their history.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// How long the app gets to read the pasted text before the clipboard is restored.
    /// Apps read it as they handle Command-V; some take a few hundred milliseconds.
    private static let restoreDelay: Duration = .seconds(1)

    /// Returns once Command-V is posted; the clipboard is restored a moment later.
    static func insert(_ text: String) -> Outcome {
        let pasteboard = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copied
        }
        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: transientType)
        let ours = pasteboard.changeCount
        postCommandV()
        Task {
            try? await Task.sleep(for: restoreDelay)
            // Something copied meanwhile is newer than what was there before.
            if pasteboard.changeCount == ours {
                restore(saved, to: pasteboard)
            }
        }
        return .pasted
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keys the user is still holding must not join the shortcut.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        let key = CGKeyCode(kVK_ANSI_V)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private static func snapshot(of pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshot.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
