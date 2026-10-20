import Foundation

/// One step of the guided spike. The user is told what to do, and the analysis
/// knows which channels should be active during it.
public struct SpikePhase: Codable, Sendable, Equatable {
    public let name: String
    public let instruction: String
    public let start: Double
    public let end: Double
    public let expectMe: Bool
    public let expectThem: Bool

    public static func standard(secondsEach: Double, startingAt origin: Double = 0) -> [SpikePhase] {
        [
            SpikePhase(
                name: "voice only",
                instruction: "Talk normally. Make sure nothing is playing on the Mac.",
                start: origin, end: origin + secondsEach, expectMe: true, expectThem: false
            ),
            SpikePhase(
                name: "system audio only",
                instruction: "Stay quiet. Play something with speech (a YouTube video or a Meet test call).",
                start: origin + secondsEach, end: origin + secondsEach * 2, expectMe: false, expectThem: true
            ),
            SpikePhase(
                name: "both",
                instruction: "Keep the audio playing and talk over it.",
                start: origin + secondsEach * 2, end: origin + secondsEach * 3, expectMe: true, expectThem: true
            ),
        ]
    }
}

public struct ChannelInfo: Codable, Sendable {
    public let speaker: Speaker
    public let backend: String
    public let device: String
    public let nativeFormat: String

    public init(speaker: Speaker, backend: String, device: String, nativeFormat: String) {
        self.speaker = speaker
        self.backend = backend
        self.device = device
        self.nativeFormat = nativeFormat
    }
}

public struct ChannelSummary: Codable, Sendable {
    public let info: ChannelInfo
    public let samplesReceived: Int
    public let samplesExpected: Int
    public let firstAudioAfterMs: Double?
    public let chunkCount: Int
    public let chunkIntervalMeanMs: Double?
    public let chunkIntervalP95Ms: Double?
    public let longestGapMs: Double?
    public let allSamplesZero: Bool

    public var deliveredRatio: Double {
        if samplesExpected == 0 {
            return 0
        }
        return Double(samplesReceived) / Double(samplesExpected)
    }
}

public struct ChannelPhaseStats: Codable, Sendable {
    public let meanDBFS: Double
    public let activeRatio: Double
    public let windowCount: Int
}

public struct PhaseResult: Codable, Sendable {
    public let phase: SpikePhase
    public let me: ChannelPhaseStats
    public let them: ChannelPhaseStats
}

public struct Verdict: Codable, Sendable {
    public let check: String
    public let passed: Bool
    public let detail: String
}

public struct SpikeReport: Codable, Sendable {
    public let createdAt: Date
    public let osVersion: String
    public let voiceProcessing: Bool
    public let captureSeconds: Double
    public let cpuPercentOfOneCore: Double?
    public let channels: [ChannelSummary]
    public let phases: [PhaseResult]
    /// Correlation between the two channels' loudness while only system audio plays.
    /// Close to 1 means the microphone is hearing the speakers.
    public let bleedCorrelation: Double?
    public let verdicts: [Verdict]

    public var allPassed: Bool { verdicts.allSatisfy(\.passed) }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public func renderText() -> String {
        var lines: [String] = []
        lines.append("Audio spike report (\(osVersion))")
        lines.append("")
        for channel in channels {
            let info = channel.info
            lines.append(
                "\(info.speaker.rawValue): \(info.backend), device \"\(info.device)\", native \(info.nativeFormat)")
            lines.append(
                "  delivered \(percent(channel.deliveredRatio)) of expected audio, \(channel.chunkCount) chunks"
                    + ", interval mean \(ms(channel.chunkIntervalMeanMs)) p95 \(ms(channel.chunkIntervalP95Ms))"
                    + ", longest gap \(ms(channel.longestGapMs)), first audio after \(ms(channel.firstAudioAfterMs))")
        }
        if let cpuPercentOfOneCore {
            lines.append("CPU: \(String(format: "%.1f", cpuPercentOfOneCore))% of one core while capturing")
        }
        lines.append("")
        for result in phases {
            lines.append("Phase \"\(result.phase.name)\": Me \(level(result.me)), Them \(level(result.them))")
        }
        if let bleedCorrelation {
            lines.append(
                "Me/Them loudness correlation while only system audio played: \(String(format: "%.2f", bleedCorrelation))"
            )
        }
        lines.append("")
        for verdict in verdicts {
            lines.append("[\(verdict.passed ? "PASS" : "FAIL")] \(verdict.check): \(verdict.detail)")
        }
        return lines.joined(separator: "\n")
    }

    private func level(_ stats: ChannelPhaseStats) -> String {
        "\(String(format: "%.0f", stats.meanDBFS)) dBFS, active \(percent(stats.activeRatio))"
    }

    private func percent(_ ratio: Double) -> String {
        String(format: "%.0f%%", ratio * 100)
    }

    private func ms(_ value: Double?) -> String {
        guard let value else {
            return "n/a"
        }
        return String(format: "%.0f ms", value)
    }
}
