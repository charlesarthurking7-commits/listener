/// What a global hotkey does.
public enum HotkeyAction: String, Sendable, CaseIterable {
    case quickAnswer
    case deepAnswer
    case recap
    case toggleListening
    case toggleWindow

    public var title: String {
        switch self {
        case .quickAnswer: "Quick answer"
        case .deepAnswer: "Deep answer"
        case .recap: "Recap so far"
        case .toggleListening: "Start or stop listening"
        case .toggleWindow: "Show or hide the window"
        }
    }

    /// The key in settings.json, e.g. "hotkeys.quickAnswer".
    public var settingKey: String { "hotkeys.\(rawValue)" }
}

public struct HotkeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let control = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let shift = HotkeyModifiers(rawValue: 1 << 2)
    public static let command = HotkeyModifiers(rawValue: 1 << 3)

    /// In the order macOS menus show them.
    static let ordered: [(modifier: HotkeyModifiers, symbol: String, spoken: String)] = [
        (.control, "⌃", "Control"),
        (.option, "⌥", "Option"),
        (.shift, "⇧", "Shift"),
        (.command, "⌘", "Command"),
    ]

    static let aliases: [String: HotkeyModifiers] = [
        "ctrl": .control, "control": .control, "⌃": .control,
        "option": .option, "opt": .option, "alt": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
        "cmd": .command, "command": .command, "⌘": .command,
    ]
}

/// A key a hotkey can use. `keyCode` is the macOS virtual key code (kVK_* in
/// HIToolbox/Events.h), which names a physical key position on an ANSI keyboard.
public struct HotkeyKey: Sendable, Hashable {
    /// The name used in settings, e.g. "space" or "k".
    public let name: String
    public let keyCode: UInt16
    /// How menus and hints show it, e.g. "Space" or "K".
    public let display: String

    public var isFunctionKey: Bool {
        name.count >= 2 && name.first == "f" && Int(name.dropFirst()) != nil
    }

    static let all: [HotkeyKey] = letters + digits + named + punctuation + functionKeys

    static let byName: [String: HotkeyKey] = {
        var table: [String: HotkeyKey] = [:]
        for key in all {
            table[key.name] = key
        }
        for (alias, name) in [("enter", "return"), ("esc", "escape"), ("spacebar", "space")] {
            table[alias] = table[name]
        }
        for key in punctuation {
            table[key.display] = key
        }
        return table
    }()

    private static let letters: [HotkeyKey] = [
        ("a", 0x00), ("b", 0x0B), ("c", 0x08), ("d", 0x02), ("e", 0x0E), ("f", 0x03), ("g", 0x05),
        ("h", 0x04), ("i", 0x22), ("j", 0x26), ("k", 0x28), ("l", 0x25), ("m", 0x2E), ("n", 0x2D),
        ("o", 0x1F), ("p", 0x23), ("q", 0x0C), ("r", 0x0F), ("s", 0x01), ("t", 0x11), ("u", 0x20),
        ("v", 0x09), ("w", 0x0D), ("x", 0x07), ("y", 0x10), ("z", 0x06),
    ].map { HotkeyKey(name: $0.0, keyCode: $0.1, display: $0.0.uppercased()) }

    private static let digits: [HotkeyKey] = [
        ("0", 0x1D), ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15),
        ("5", 0x17), ("6", 0x16), ("7", 0x1A), ("8", 0x1C), ("9", 0x19),
    ].map { HotkeyKey(name: $0.0, keyCode: $0.1, display: $0.0) }

    private static let named: [HotkeyKey] = [
        HotkeyKey(name: "space", keyCode: 0x31, display: "Space"),
        HotkeyKey(name: "return", keyCode: 0x24, display: "Return"),
        HotkeyKey(name: "tab", keyCode: 0x30, display: "Tab"),
        HotkeyKey(name: "escape", keyCode: 0x35, display: "Esc"),
    ]

    private static let punctuation: [HotkeyKey] = [
        ("minus", 0x1B, "-"), ("equal", 0x18, "="), ("leftbracket", 0x21, "["), ("rightbracket", 0x1E, "]"),
        ("semicolon", 0x29, ";"), ("quote", 0x27, "'"), ("backslash", 0x2A, "\\"), ("comma", 0x2B, ","),
        ("period", 0x2F, "."), ("slash", 0x2C, "/"), ("grave", 0x32, "`"),
    ].map { HotkeyKey(name: $0.0, keyCode: $0.1, display: $0.2) }

    private static let functionKeys: [HotkeyKey] = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
    ].enumerated().map { index, code in
        HotkeyKey(name: "f\(index + 1)", keyCode: code, display: "F\(index + 1)")
    }
}

public enum HotkeyError: Error, Equatable, CustomStringConvertible {
    case empty
    case unknownPart(String)
    case missingKey
    case moreThanOneKey(String, String)
    case needsModifier
    case blockedByMacOS

    public var description: String {
        switch self {
        case .empty:
            "is empty"
        case .unknownPart(let part):
            "\"\(part)\" is not a modifier (ctrl, option, shift, cmd) or a key (a to z, 0 to 9, space, return, f1 to f12)"
        case .missingKey:
            "has modifiers but no key"
        case .moreThanOneKey(let first, let second):
            "has two keys, \"\(first)\" and \"\(second)\""
        case .needsModifier:
            "needs ctrl, option or cmd, otherwise it would take over that key in every app"
        case .blockedByMacOS:
            "uses only option or option+shift, which macOS 15 does not allow for global hotkeys; add ctrl or cmd"
        }
    }
}

/// A global keyboard shortcut written like "ctrl+option+space".
public struct Hotkey: Sendable, Hashable {
    public var key: HotkeyKey
    public var modifiers: HotkeyModifiers

    public init(key: HotkeyKey, modifiers: HotkeyModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Parses "ctrl+option+shift+space". Case and spaces around "+" don't matter.
    public init(parsing text: String) throws(HotkeyError) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.allSatisfy(\.isEmpty) {
            throw .empty
        }

        var modifiers: HotkeyModifiers = []
        var key: HotkeyKey?
        for part in parts {
            if let modifier = HotkeyModifiers.aliases[part] {
                modifiers.insert(modifier)
            } else if let found = HotkeyKey.byName[part] {
                if let key {
                    throw .moreThanOneKey(key.name, found.name)
                }
                key = found
            } else {
                throw .unknownPart(part)
            }
        }
        guard let key else {
            throw .missingKey
        }
        if !key.isFunctionKey {
            if modifiers.isDisjoint(with: [.control, .option, .command]) {
                throw .needsModifier
            }
            if modifiers == .option || modifiers == [.option, .shift] {
                throw .blockedByMacOS
            }
        }
        self.init(key: key, modifiers: modifiers)
    }

    /// The menu spelling, e.g. "⌃⌥Space".
    public var displayString: String {
        keycaps.joined()
    }

    /// One label per key to draw as keycaps, e.g. ["⌃", "⌥", "Space"].
    public var keycaps: [String] {
        HotkeyModifiers.ordered.filter { modifiers.contains($0.modifier) }.map(\.symbol) + [key.display]
    }

    /// What VoiceOver reads, e.g. "Control Option Space".
    public var spokenName: String {
        (HotkeyModifiers.ordered.filter { modifiers.contains($0.modifier) }.map(\.spoken) + [key.display])
            .joined(separator: " ")
    }
}

extension HotkeySettings {
    public func binding(for action: HotkeyAction) -> String {
        switch action {
        case .quickAnswer: quickAnswer
        case .deepAnswer: deepAnswer
        case .recap: recap
        case .toggleListening: toggleListening
        case .toggleWindow: toggleWindow
        }
    }

    /// Every configured hotkey that parses, by action.
    public var hotkeys: [HotkeyAction: Hotkey] {
        var result: [HotkeyAction: Hotkey] = [:]
        for action in HotkeyAction.allCases {
            result[action] = try? Hotkey(parsing: binding(for: action))
        }
        return result
    }

    /// One problem per hotkey that is invalid or used twice. Messages name the setting.
    public var problems: [HotkeyProblem] {
        var problems: [HotkeyProblem] = []
        var seen: [Hotkey: HotkeyAction] = [:]
        for action in HotkeyAction.allCases {
            let text = binding(for: action)
            do {
                let hotkey = try Hotkey(parsing: text)
                if let other = seen[hotkey] {
                    problems.append(
                        HotkeyProblem(
                            action: action,
                            message: "\(action.settingKey) \"\(text)\" is the same as \(other.settingKey)"
                        ))
                } else {
                    seen[hotkey] = action
                }
            } catch {
                problems.append(HotkeyProblem(action: action, message: "\(action.settingKey) \"\(text)\" \(error)"))
            }
        }
        return problems
    }
}

public struct HotkeyProblem: Sendable, Equatable {
    public var action: HotkeyAction
    public var message: String
}
