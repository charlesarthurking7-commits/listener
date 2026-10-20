/// Maps one clock onto another that runs at the same rate but can jump against it, for
/// example a channel's audio position onto session time (capture gaps make it jump) or
/// a speech-to-text stream's audio position onto the channel's (skipped silence and
/// reconnects make it jump).
///
/// Each anchor fixes the offset from its point onwards. A new anchor is only stored when
/// the offset moves by more than `tolerance`, so jitter does not grow the map.
public struct TimeMap: Sendable, Equatable {
    private struct Anchor: Sendable, Equatable {
        var from: Double
        var offset: Double
    }

    public let tolerance: Double
    private var anchors: [Anchor] = []

    public init(tolerance: Double) {
        self.tolerance = tolerance
    }

    public var isEmpty: Bool { anchors.isEmpty }

    /// Records that `from` on the source clock is `to` on the target clock. Points must
    /// arrive in increasing `from` order; one that goes backwards is ignored.
    public mutating func record(from: Double, to: Double) {
        let offset = to - from
        if let last = anchors.last, abs(offset - last.offset) <= tolerance || from <= last.from {
            return
        }
        anchors.append(Anchor(from: from, offset: offset))
    }

    /// The target-clock time of `value`. Before the first anchor the first offset
    /// applies; an empty map is the identity.
    public func map(_ value: Double) -> Double {
        value + offset(at: value, endingThere: false)
    }

    /// The target-clock time of `value` as the end of a stretch of time. At a jump the
    /// end of what came before and the start of what follows are the same source time;
    /// an end belongs to what came before.
    public func mapEnd(_ value: Double) -> Double {
        value + offset(at: value, endingThere: true)
    }

    /// The offset of the last anchor at or before `value`. Within `tolerance` of an
    /// anchor counts as at it, so sums of frame lengths that land a hair either side of
    /// a jump are still at the jump: a start there takes the anchor, an end does not.
    private func offset(at value: Double, endingThere: Bool) -> Double {
        guard !anchors.isEmpty else {
            return 0
        }
        let edge = endingThere ? value - tolerance : value + tolerance
        var low = 0
        var high = anchors.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if anchors[middle].from < edge {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return anchors[low].offset
    }
}
