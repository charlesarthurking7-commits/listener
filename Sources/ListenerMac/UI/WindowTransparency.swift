import Foundation

/// How much of what is behind the window shows through. Glass blurs it; Clear doesn't,
/// and tints it dark under light text instead, and fades between answers in a call.
enum WindowTransparency: String, CaseIterable, Sendable {
    case solid
    case glass
    case clear

    static let key = "transparency"
    /// See-through enough to forget, solid enough to find.
    static let clearIdleOpacity = 0.35

    static var stored: WindowTransparency {
        UserDefaults.standard.string(forKey: key).flatMap(WindowTransparency.init) ?? .glass
    }

    var title: String {
        switch self {
        case .solid: "Solid"
        case .glass: "Glass"
        case .clear: "Clear"
        }
    }
}
