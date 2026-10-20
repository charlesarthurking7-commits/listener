import Foundation

/// How times, money and latencies read in the window and the terminal.
public enum DisplayFormat {
    /// Elapsed time: "0:07", "12:05", "1:02:03".
    public static func clock(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let rest = total % 60
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(rest))"
        }
        return "\(minutes):\(twoDigits(rest))"
    }

    /// A running total: "$0.00", "<$0.01", "$1.92".
    public static func cost(_ dollars: Double) -> String {
        if dollars <= 0 {
            return "$0.00"
        }
        if dollars < 0.01 {
            return "<$0.01"
        }
        return String(format: "$%.2f", dollars)
    }

    /// One answer's cost, which is usually a fraction of a cent: "$0.0006".
    public static func preciseCost(_ dollars: Double) -> String {
        if dollars >= 1 {
            return String(format: "$%.2f", dollars)
        }
        return String(format: "$%.4f", dollars)
    }

    /// "640 ms", "1.24 s", "12.5 s", or "-" when there is no measurement.
    public static func latency(milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite else {
            return "-"
        }
        if abs(milliseconds) < 1000 {
            return "\(Int(milliseconds.rounded())) ms"
        }
        if abs(milliseconds) < 10_000 {
            return String(format: "%.2f s", milliseconds / 1000)
        }
        return String(format: "%.1f s", milliseconds / 1000)
    }

    /// A model ID as people say it: "claude-haiku-5-5" is "Haiku 5.5" and
    /// "claude-3-5-sonnet-20241022" is "Sonnet 3.5". Anything else is shown unchanged.
    public static func modelName(_ id: String) -> String {
        let parts = id.lowercased().split(separator: "-")
        guard parts.first == "claude" else {
            return id
        }
        var family: Substring?
        var version: [Substring] = []
        for part in parts.dropFirst() {
            if part.allSatisfy(\.isLetter), family == nil {
                family = part
            } else if part.count <= 2, part.allSatisfy(\.isNumber) {
                version.append(part)
            }
        }
        guard let family else {
            return id
        }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

/// Turns any error into one line a person can act on.
public enum ErrorText {
    public static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        // On macOS every error bridges to NSError, so a cast to CustomStringConvertible
        // always succeeds. Swift error types bridge with a "Module.Type" domain and
        // describe themselves best; Foundation's domains have no dot and come with a
        // readable localizedDescription.
        let bridged = error as NSError
        if bridged.domain.contains(".") {
            return String(describing: error)
        }
        return bridged.localizedDescription
    }
}
