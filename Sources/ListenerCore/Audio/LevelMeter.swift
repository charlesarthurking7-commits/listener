import Foundation

public enum LevelMeter {
    /// Level reported for digital silence. A real microphone never gets this low,
    /// so seeing it on a channel usually means a missing permission.
    public static let floorDBFS = -96.0

    public static func rmsDBFS<Samples: Collection<Int16>>(_ samples: Samples) -> Double {
        if samples.isEmpty {
            return floorDBFS
        }
        var sumOfSquares = 0.0
        for sample in samples {
            let normalised = Double(sample) / 32768.0
            sumOfSquares += normalised * normalised
        }
        let rms = (sumOfSquares / Double(samples.count)).squareRoot()
        if rms == 0 {
            return floorDBFS
        }
        return max(20 * log10(rms), floorDBFS)
    }

    public static func isDigitalSilence<Samples: Collection<Int16>>(_ samples: Samples) -> Bool {
        samples.allSatisfy { $0 == 0 }
    }

    /// A fixed-width bar for terminal meters, e.g. "#######-------".
    public static func bar(dbfs: Double, width: Int = 20, floor: Double = -70) -> String {
        let clamped = min(max(dbfs, floor), 0)
        let filled = Int(((clamped - floor) / -floor * Double(width)).rounded())
        return String(repeating: "#", count: filled) + String(repeating: "-", count: width - filled)
    }
}
