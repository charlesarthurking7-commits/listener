/// Watches the rate a capture source really delivers frames at, for as long as it runs,
/// so a format that misstates it, or a device that changes rate without saying so, is
/// caught within a few seconds.
///
/// A system audio tap clocked by AirPods in call mode reports 48 kHz while its frames
/// arrive at 24 kHz, and the AirPods only switch to call mode when a call app opens
/// their mic, which can be well after Start. Read at the wrong rate, the other side
/// plays at double speed and an octave up, which speech recognition turns into nonsense.
///
/// The rate is measured over one-second spans and only acted on when two in a row agree,
/// so a span that straddles a switch, and reads somewhere in between, never counts.
public struct DeliveredRateMonitor: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Frames arrive at the rate they are read at. Reported once, the first time.
        case matches(measured: Double)
        /// Frames arrive at another standard rate, which they are read at from now on.
        case corrected(from: Double, to: Double, measured: Double)
        /// Frames arrive at a rate no device runs at, so the current one stands. Reported
        /// once until the rate settles again.
        case unexplained(measured: Double)
    }

    public static let standardRates: [Double] = [
        8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000,
    ]
    /// Drift compensation and timing jitter stay well inside this.
    static let matchTolerance = 0.05
    static let snapTolerance = 0.03
    /// How closely two spans in a row must agree to count as a steady rate.
    static let steadyTolerance = 0.02

    /// The rate the audio is read at.
    public private(set) var rate: Double
    /// Seconds skipped after a start, a break or a correction: delivery can come in a
    /// burst while a device settles.
    public let warmUp: Double
    /// Seconds per measured span.
    public let span: Double
    /// A longer break in delivery starts over, as a stall would read as a slow rate.
    public let maxPause: Double

    private var settledAt: Double?
    private var lastTime: Double?
    private var spanStart: Double?
    private var framesInSpan = 0
    private var previousSpanRate: Double?
    private var hasMatched = false
    private var hasReportedUnexplained = false

    public init(rate: Double, warmUp: Double = 0.5, span: Double = 1, maxPause: Double = 0.25) {
        self.rate = rate
        self.warmUp = warmUp
        self.span = span
        self.maxPause = maxPause
    }

    /// Takes the next buffer: its frame count and the time of its first frame, in seconds
    /// on any steady clock. Returns an outcome when there is something to report.
    public mutating func record(frames: Int, at time: Double) -> Outcome? {
        defer { lastTime = time }
        if let lastTime, time < lastTime || time - lastTime > maxPause {
            startOver(at: time)
        }
        let settled = settledAt ?? time + warmUp
        settledAt = settled
        if time < settled {
            return nil
        }
        // A span's rate is the frames of its buffers over the time from its first buffer
        // to the one after its last.
        guard let start = spanStart else {
            spanStart = time
            framesInSpan = frames
            return nil
        }
        let elapsed = time - start
        guard elapsed >= span else {
            framesInSpan += frames
            return nil
        }
        let spanRate = Double(framesInSpan) / elapsed
        spanStart = time
        framesInSpan = frames
        let previousRate = previousSpanRate
        previousSpanRate = spanRate
        guard let previous = previousRate, abs(spanRate / previous - 1) <= Self.steadyTolerance else {
            return nil
        }
        return judge((spanRate + previous) / 2, at: time)
    }

    private mutating func judge(_ measured: Double, at time: Double) -> Outcome? {
        if abs(measured / rate - 1) <= Self.matchTolerance {
            hasReportedUnexplained = false
            defer { hasMatched = true }
            return hasMatched ? nil : .matches(measured: measured)
        }
        let nearest = Self.standardRates.min { abs($0 - measured) < abs($1 - measured) } ?? rate
        if abs(nearest / measured - 1) <= Self.snapTolerance {
            let previous = rate
            rate = nearest
            hasMatched = true
            hasReportedUnexplained = false
            startOver(at: time)
            return .corrected(from: previous, to: nearest, measured: measured)
        }
        if hasReportedUnexplained {
            return nil
        }
        hasReportedUnexplained = true
        return .unexplained(measured: measured)
    }

    private mutating func startOver(at time: Double) {
        settledAt = time + warmUp
        spanStart = nil
        previousSpanRate = nil
    }
}
