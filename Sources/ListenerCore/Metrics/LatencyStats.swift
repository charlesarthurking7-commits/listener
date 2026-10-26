/// Median and 90th percentile of each answer latency stage over a session, in
/// milliseconds. A stage is nil when no answer measured it.
public struct LatencyStats: Sendable, Codable, Equatable {
    public struct Percentiles: Sendable, Codable, Equatable {
        public var count: Int
        public var p50: Double
        public var p90: Double
    }

    public var endOfSpeechToHotkey: Percentiles?
    public var finalToHotkey: Percentiles?
    public var hotkeyToRequestSent: Percentiles?
    public var hotkeyToFirstToken: Percentiles?
    public var hotkeyToDone: Percentiles?
    public var endOfSpeechToFirstToken: Percentiles?

    public init(_ latencies: [AnswerLatency]) {
        endOfSpeechToHotkey = Percentiles(latencies.compactMap(\.endOfSpeechToHotkey))
        finalToHotkey = Percentiles(latencies.compactMap(\.finalToHotkey))
        hotkeyToRequestSent = Percentiles(latencies.compactMap(\.hotkeyToRequestSent))
        hotkeyToFirstToken = Percentiles(latencies.compactMap(\.hotkeyToFirstToken))
        hotkeyToDone = Percentiles(latencies.compactMap(\.hotkeyToDone))
        endOfSpeechToFirstToken = Percentiles(latencies.compactMap(\.endOfSpeechToFirstToken))
    }
}

extension LatencyStats.Percentiles {
    /// Nil for no values. Percentiles interpolate between the nearest ranks.
    public init?(_ values: [Double]) {
        guard !values.isEmpty else {
            return nil
        }
        let sorted = values.sorted()
        self.init(count: sorted.count, p50: percentile(sorted, 0.5), p90: percentile(sorted, 0.9))
    }
}

/// The value `fraction` of the way through `sorted`, which must not be empty,
/// interpolating between the nearest ranks.
func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    let rank = fraction * Double(sorted.count - 1)
    let lower = Int(rank.rounded(.down))
    let upper = min(lower + 1, sorted.count - 1)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - Double(lower))
}
