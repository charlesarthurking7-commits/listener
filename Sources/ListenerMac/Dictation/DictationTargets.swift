import AppKit
import ListenerCore

/// Where dictated text goes, as the clean-up sees it, the font at the cursor for pasting
/// a formatted list in, and the field and cursor position for watching for corrections.
struct DictationDestination {
    var target = DictationTarget()
    var font: NSFont?
    var field: AXUIElement?
    /// Where the cursor was in the field, in UTF-16 units, so where the text goes in.
    var cursor: Int?
}

/// Where dictated text goes: the app in front, its window, and the text and font either
/// side of the cursor in the field being typed into, read through Accessibility.
@MainActor
enum DictationTargets {
    /// How long to wait on an app that is slow to answer.
    private static let timeout: Float = 0.2
    /// Text read on each side of the cursor: enough for the sentence being continued and
    /// the names in an email being answered.
    static let contextCharacters = 500

    static func current() -> DictationDestination {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return DictationDestination()
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, timeout)
        // Chromium and Electron apps only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var target = DictationTarget(
            appName: app.localizedName, bundleID: app.bundleIdentifier,
            windowTitle: element.child(kAXFocusedWindowAttribute)?.string(kAXTitleAttribute))
        guard let field = element.child(kAXFocusedUIElementAttribute),
            field.string(kAXSubroleAttribute) != kAXSecureTextFieldSubrole
        else {
            Log.dictation.debug("No text field has the focus in \(app.localizedName ?? "?", privacy: .public)")
            return DictationDestination(target: target)
        }
        (target.textBeforeCursor, target.textAfterCursor) = textAroundCursor(in: field)
        let font = cursorFont(in: field)
        let cursor = field.range(kAXSelectedTextRangeAttribute)?.location
        // Which apps share their text decides what the clean-up and the dictionary get.
        Log.dictation.debug(
            """
            \(app.localizedName ?? "?", privacy: .public) shares \(target.textBeforeCursor?.count ?? -1) characters \
            before the cursor and \(target.textAfterCursor?.count ?? -1) after, \
            font \(font == nil ? "unknown" : "known", privacy: .public), position \(cursor ?? -1)
            """)
        return DictationDestination(target: target, font: font, field: field, cursor: cursor)
    }

    /// The font of the character before the cursor, or after it at the start, as Cocoa
    /// text views report it. Web views don't, and need no font: they use their own.
    private static func cursorFont(in field: AXUIElement) -> NSFont? {
        guard let selection = field.range(kAXSelectedTextRangeAttribute) else {
            return nil
        }
        var range = CFRange(location: max(selection.location - 1, 0), length: 1)
        var value: CFTypeRef?
        guard let parameter = AXValueCreate(.cfRange, &range),
            AXUIElementCopyParameterizedAttributeValue(
                field, kAXAttributedStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
            let text = value as? NSAttributedString, text.length > 0,
            let font = text.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any],
            let name = font["AXFontName"] as? String, let size = font["AXFontSize"] as? NSNumber
        else {
            return nil
        }
        return NSFont(name: name, size: CGFloat(truncating: size))
    }

    private static func textAroundCursor(in field: AXUIElement) -> (String?, String?) {
        guard let selection = field.range(kAXSelectedTextRangeAttribute) else {
            return (nil, nil)
        }
        let start = max(0, selection.location - contextCharacters)
        let afterStart = selection.location + selection.length
        let before = field.string(in: CFRange(location: start, length: selection.location - start))
        var after: String?
        let count = field.integer(kAXNumberOfCharactersAttribute) ?? afterStart + contextCharacters
        if count > afterStart {
            after = field.string(in: CFRange(location: afterStart, length: min(contextCharacters, count - afterStart)))
        }
        if before != nil || after != nil {
            return (before, after)
        }
        // Fields that can't hand out a range of their text can usually give all of it.
        guard let value = field.string(kAXValueAttribute).map({ $0 as NSString }),
            afterStart <= value.length
        else {
            return (nil, nil)
        }
        return (
            value.substring(with: NSRange(location: start, length: selection.location - start)),
            value.substring(
                with: NSRange(location: afterStart, length: min(contextCharacters, value.length - afterStart)))
        )
    }
}
