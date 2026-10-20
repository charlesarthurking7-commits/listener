import Foundation

enum SpikeMath {
    /// Averages levels in the power domain, which is what an ear (and a VU meter) does.
    /// A plain mean of dB values would let a few quiet windows drag a loud passage down.
    static func powerMean(_ levels: [Double]) -> Double {
        if levels.isEmpty {
            return LevelMeter.floorDBFS
        }
        var totalPower = 0.0
        for level in levels {
            totalPower += pow(10, level / 10)
        }
        let meanPower = totalPower / Double(levels.count)
        return max(10 * log10(meanPower), LevelMeter.floorDBFS)
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        if values.isEmpty {
            return nil
        }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count - 1)).rounded())
        return sorted[rank]
    }

    static func mean(_ values: [Double]) -> Double? {
        if values.isEmpty {
            return nil
        }
        return values.reduce(0, +) / Double(values.count)
    }

    static func pearson(_ pairs: [(Double, Double)]) -> Double? {
        if pairs.count < 10 {
            return nil
        }
        let count = Double(pairs.count)
        var sumX = 0.0
        var sumY = 0.0
        for (x, y) in pairs {
            sumX += x
            sumY += y
        }
        let meanX = sumX / count
        let meanY = sumY / count

        var covariance = 0.0
        var varianceX = 0.0
        var varianceY = 0.0
        for (x, y) in pairs {
            covariance += (x - meanX) * (y - meanY)
            varianceX += (x - meanX) * (x - meanX)
            varianceY += (y - meanY) * (y - meanY)
        }
        if varianceX == 0 || varianceY == 0 {
            return nil
        }
        return covariance / (varianceX * varianceY).squareRoot()
    }
}
