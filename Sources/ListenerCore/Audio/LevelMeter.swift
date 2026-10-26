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
}
