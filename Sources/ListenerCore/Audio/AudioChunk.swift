public enum Speaker: String, Codable, Sendable, CaseIterable {
    case me = "Me"
    case them = "Them"
}

/// A slice of captured audio, already converted to the format every speech-to-text
/// provider receives: 16 kHz, mono, signed 16-bit.
public struct AudioChunk: Sendable {
    public static let sampleRate = 16_000

    public let speaker: Speaker
    public let samples: [Int16]
    public let capturedAt: ContinuousClock.Instant

    public init(speaker: Speaker, samples: [Int16], capturedAt: ContinuousClock.Instant) {
        self.speaker = speaker
        self.samples = samples
        self.capturedAt = capturedAt
    }
}

extension Duration {
    public var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
