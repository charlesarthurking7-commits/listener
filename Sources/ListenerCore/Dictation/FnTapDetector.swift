/// Recognises taps on the fn (Globe) key from its presses and releases. A tap is fn
/// pressed and let go quickly on its own, so fn used as a modifier (fn+Delete, fn+F5)
/// never counts. Two taps close together are a double tap.
///
/// Times are seconds on any clock that only goes forward.
public struct FnTapDetector: Sendable {
    public enum Input: Sendable, Equatable {
        case fnDown
        case fnUp
        /// Any other key or modifier went down.
        case otherKey
    }

    public enum Tap: Sendable, Equatable {
        case single
        case double
    }

    /// fn held longer than this is a hold, not a tap.
    public static let maxPress = 0.35
    /// The most time from one tap's release to the next tap's press, for a double tap.
    public static let maxGap = 0.4
    /// Taps this soon after one that was acted on are part of the same burst. Longer
    /// than `maxGap`, because a slow double tap often ends with a stray third tap.
    public static let burstGap = 0.75
    /// The Globe key's own key press, which macOS sends as fn is let go. It is part of
    /// the tap, not another key.
    public static let globeKeyCode = 179

    private var pressedAt: Double?
    /// Another key went down while fn was held.
    private var usedAsModifier = false
    /// When the last single tap was released, while a second can still make it a double.
    private var lastTapAt: Double?
    /// When the last tap that was acted on was released. Taps that follow straight after
    /// it belong to the same burst and are ignored, so tapping three times starts
    /// dictation without stopping it again.
    private var actedOnAt: Double?

    public init() {}

    /// What a key press other than fn means here: nil for one that is part of fn itself.
    public static func input(forKeyDown keyCode: Int) -> Input? {
        keyCode == globeKeyCode ? nil : .otherKey
    }

    /// The tap that `input` completed, if any.
    public mutating func handle(_ input: Input, at time: Double) -> Tap? {
        switch input {
        case .fnDown:
            pressedAt = time
            usedAsModifier = false
            return nil
        case .otherKey:
            if pressedAt != nil {
                usedAsModifier = true
            }
            lastTapAt = nil
            actedOnAt = nil
            return nil
        case .fnUp:
            guard let pressedAt else {
                return nil
            }
            self.pressedAt = nil
            guard !usedAsModifier, time - pressedAt <= Self.maxPress else {
                lastTapAt = nil
                actedOnAt = nil
                return nil
            }
            if let actedOnAt, pressedAt - actedOnAt <= Self.burstGap {
                self.actedOnAt = time
                return nil
            }
            actedOnAt = nil
            if let lastTapAt, pressedAt - lastTapAt <= Self.maxGap {
                self.lastTapAt = nil
                actedOnAt = time
                return .double
            }
            lastTapAt = time
            return .single
        }
    }

    /// Marks the single tap just reported as acted on, so it cannot become the first
    /// half of a double tap: a double tap to stop dictating must not start it again.
    public mutating func actedOnSingleTap() {
        actedOnAt = lastTapAt
        lastTapAt = nil
    }
}
