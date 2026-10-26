import AppKit
import ListenerCore

/// What dictation needs from macOS, and the banners that say how to get it.
@MainActor
enum DictationSetup {
    private static let promptedKey = "dictationAccessibilityPrompted"

    static let accessibilityNotice =
        "Dictation needs Accessibility permission to hear fn and paste what you say. "
        + "Turn on Listener in Privacy & Security > Accessibility."
    static let fnKeyNotice =
        "macOS acts on fn as well. In Keyboard settings, set \"Press 🌐 key to\" to \"Do Nothing\", "
        + "and choose a Dictation shortcut that doesn't use 🌐."

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// "Press 🌐 key to" is "Do Nothing". Anything else, the emoji picker or Apple's own
    /// dictation, opens on the same presses as ours.
    static var fnKeyIsFree: Bool {
        (UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int) == 0
    }

    /// macOS's own request, which adds Listener to the Accessibility list. Only the
    /// first time: after that the banner and the menu say where to turn it on.
    static func requestAccessibilityOnce() {
        guard !hasAccessibility, !UserDefaults.standard.bool(forKey: promptedKey) else {
            return
        }
        UserDefaults.standard.set(true, forKey: promptedKey)
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 can't read as a global.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: PrivacyPane.accessibility.url) {
            NSWorkspace.shared.open(url)
        }
    }

    static let accessibilityAction = NoticeAction.openURL(PrivacyPane.accessibility.url, title: "Open Settings")
    static let keyboardAction = NoticeAction.openURL(
        "x-apple.systempreferences:com.apple.Keyboard-Settings.extension", title: "Open Keyboard Settings")
}
