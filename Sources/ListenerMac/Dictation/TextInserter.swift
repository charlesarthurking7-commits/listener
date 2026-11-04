import AppKit
import Carbon
import ListenerCore

/// Types text into the app in front by pasting it: the text goes on the clipboard,
/// Command-V is posted, and the clipboard is put back as it was. Pasting works in every
/// app, native or not, where typing key by key is slow and trips over keyboard layouts.
/// Return can follow, to send a message.
@MainActor
enum TextInserter {
    /// The text, and for a list, formatted versions of it: apps take the richest they
    /// can. Web views (Outlook, Teams, Slack, Gmail) take HTML, Cocoa text views (Notes,
    /// Mail, TextEdit) RTF, and everything else the plain text.
    struct Paste {
        var text: String
        var html: String?
        var rtf: Data?

        init(_ text: String, formattingLists: Bool, font: NSFont?) {
            self.text = text
            let blocks = formattingLists ? DictationFormatting.blocks(for: text) : nil
            html = blocks.map(DictationFormatting.html)
            rtf = blocks.flatMap { Self.rtf($0, font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)) }
        }

        /// RTF in the font at the cursor, which Cocoa takes before HTML and would otherwise
        /// read as Times. Lists are laid out as TextEdit lays out its own, and no colour is
        /// set, so the text follows dark mode.
        private static func rtf(_ blocks: [DictationFormatting.Block], font: NSFont) -> Data? {
            let text = NSMutableAttributedString()
            let plain = NSParagraphStyle.default
            func add(_ string: String, _ style: NSParagraphStyle) {
                text.append(NSAttributedString(string: string, attributes: [.font: font, .paragraphStyle: style]))
            }
            for (index, block) in blocks.enumerated() {
                let end = index == blocks.count - 1 ? "" : "\n"
                switch block {
                case .line(let line):
                    add(line + end, plain)
                case .blank:
                    add(end, plain)
                case .list(let numbered, let start, let items):
                    let list = NSTextList(
                        markerFormat: numbered ? NSTextList.MarkerFormat("{decimal}.") : .disc, options: 0)
                    list.startingItemNumber = start
                    let style = NSMutableParagraphStyle()
                    style.textLists = [list]
                    style.tabStops = [
                        NSTextTab(textAlignment: .left, location: 11), NSTextTab(textAlignment: .left, location: 36),
                    ]
                    style.headIndent = 36
                    for (offset, item) in items.enumerated() {
                        let marker = list.marker(forItemNumber: start + offset)
                        add("\t\(marker)\t\(item)" + (offset == items.count - 1 ? end : "\n"), style)
                    }
                }
            }
            return text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:])
        }
    }

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
    /// Web apps such as Teams can put pasted text in a moment after Command-V, and Return
    /// before then would send the message without it.
    private static let returnDelay: Duration = .milliseconds(200)

    /// Returns once Command-V is posted; Return and restoring the clipboard follow.
    static func insert(_ paste: Paste, pressingReturn: Bool = false) -> Outcome {
        let pasteboard = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            put(paste, on: pasteboard)
            return .copied
        }
        let saved = snapshot(of: pasteboard)
        put(paste, on: pasteboard)
        pasteboard.setData(Data(), forType: transientType)
        let ours = pasteboard.changeCount
        post(kVK_ANSI_V, flags: .maskCommand)
        if pressingReturn {
            Task {
                try? await Task.sleep(for: returnDelay)
                pressReturn()
            }
        }
        Task {
            try? await Task.sleep(for: restoreDelay)
            // Something copied meanwhile is newer than what was there before.
            if pasteboard.changeCount == ours {
                restore(saved, to: pasteboard)
            }
        }
        return .pasted
    }

    static func put(_ paste: Paste, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(paste.text, forType: .string)
        if let html = paste.html {
            pasteboard.setString(html, forType: .html)
        }
        if let rtf = paste.rtf {
            pasteboard.setData(rtf, forType: .rtf)
        }
    }

    /// Presses Return in the app in front.
    static func pressReturn() {
        post(kVK_Return, flags: [])
    }

    private static func post(_ key: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keys the user is still holding must not join in.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: isDown)
            event?.flags = flags
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
