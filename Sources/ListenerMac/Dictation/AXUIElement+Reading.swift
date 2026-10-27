import ApplicationServices
import Foundation

/// Typed reads of an app's accessibility elements, for dictation's targets and the
/// correction watcher.
extension AXUIElement {
    func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success ? value : nil
    }

    func child(_ name: String) -> AXUIElement? {
        guard let value = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    func string(_ name: String) -> String? {
        attribute(name) as? String
    }

    func integer(_ name: String) -> Int? {
        (attribute(name) as? NSNumber)?.intValue
    }

    func range(_ name: String) -> CFRange? {
        guard let value = attribute(name), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    /// The field's text in `range`, counted in UTF-16 units as Accessibility counts them.
    func string(in range: CFRange) -> String? {
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
