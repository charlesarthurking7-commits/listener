import AppKit
import ListenerCore

/// Where dictated text goes: the app in front, its window, and the text either side of
/// the cursor in the field being typed into, read through Accessibility.
@MainActor
enum DictationTargets {
    /// How long to wait on an app that is slow to answer.
    private static let timeout: Float = 0.2
    /// Text read on each side of the cursor: enough for the sentence being continued and
    /// the names in an email being answered.
    static let contextCharacters = 500

    static func current() -> DictationTarget {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return DictationTarget()
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, timeout)
        // Chromium and Electron apps only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var target = DictationTarget(
            appName: app.localizedName, bundleID: app.bundleIdentifier,
            windowTitle: element.child(kAXFocusedWindowAttribute)?.string(kAXTitleAttribute))
        if let field = element.child(kAXFocusedUIElementAttribute),
            field.string(kAXSubroleAttribute) != kAXSecureTextFieldSubrole
        {
            (target.textBeforeCursor, target.textAfterCursor) = textAroundCursor(in: field)
        }
        return target
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

extension AXUIElement {
    fileprivate func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success ? value : nil
    }

    fileprivate func child(_ name: String) -> AXUIElement? {
        guard let value = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    fileprivate func string(_ name: String) -> String? {
        attribute(name) as? String
    }

    fileprivate func integer(_ name: String) -> Int? {
        (attribute(name) as? NSNumber)?.intValue
    }

    fileprivate func range(_ name: String) -> CFRange? {
        guard let value = attribute(name), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    /// The field's text in `range`, counted in UTF-16 units as Accessibility counts them.
    fileprivate func string(in range: CFRange) -> String? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else {
            return nil
        }
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            self, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
        return status == .success ? value as? String : nil
    }
}
