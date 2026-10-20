import Foundation

/// Level of one 100 ms slice of audio, stamped with when it finished arriving.
public struct LevelWindow: Sendable, Equatable {
    public let dbfs: Double
    public let endOffset: Double

    public init(dbfs: Double, endOffset: Double) {
        self.dbfs = dbfs
        self.endOffset = endOffset
    }
}

/// Everything the spike needs to know about one channel, built up chunk by chunk.
/// Offsets are seconds since the capture started.
public struct ChannelTrace: Sendable {
    public static let windowSampleCount = AudioChunk.sampleRate / 10

    public private(set) var sampleCount = 0
    public private(set) var chunkOffsets: [Double] = []
    public private(set) var windows: [LevelWindow] = []
    public private(set) var sawNonZeroSample = false
    private var pending: [Int16] = []

    public init() {}

    public mutating func append(_ samples: [Int16], atOffset offset: Double) {
        sampleCount += samples.count
        chunkOffsets.append(offset)
        if !sawNonZeroSample && !LevelMeter.isDigitalSilence(samples) {
            sawNonZeroSample = true
        }

        pending.append(contentsOf: samples)
        var consumed = 0
        while pending.count - consumed >= Self.windowSampleCount {
            let window = pending[consumed..<consumed + Self.windowSampleCount]
            windows.append(LevelWindow(dbfs: LevelMeter.rmsDBFS(window), endOffset: offset))
            consumed += Self.windowSampleCount
        }
        pending.removeFirst(consumed)
    }

    public var firstChunkOffset: Double? { chunkOffsets.first }

    /// Average level of the windows that ended after `offset`, for live meters.
    public func level(since offset: Double) -> Double {
        var recent: [Double] = []
        for window in windows.reversed() {
            if window.endOffset <= offset {
                break
            }
            recent.append(window.dbfs)
        }
        return SpikeMath.powerMean(recent)
    }

    public func windows(from start: Double, to end: Double) -> [LevelWindow] {
        windows.filter { $0.endOffset > start && $0.endOffset <= end }
    }

    public func chunkIntervals() -> [Double] {
        var intervals: [Double] = []
        if chunkOffsets.count < 2 {
            return intervals
        }
        for index in 1..<chunkOffsets.count {
            intervals.append(chunkOffsets[index] - chunkOffsets[index - 1])
        }
        return intervals
    }
}
