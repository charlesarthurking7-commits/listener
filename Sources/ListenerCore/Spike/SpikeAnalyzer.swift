import Foundation

public struct SpikeAnalyzer {
    /// A 100 ms window louder than this counts as someone speaking. Speech into a
    /// headset sits around -35 to -20 dBFS; a quiet room's noise floor is below -55.
    public var activeThresholdDBFS = -45.0
    /// A channel "carries" a phase when it is active at least this often...
    public var minimumActiveRatio = 0.2
    /// ...and counts as quiet when it is active at most this often.
    public var maximumLeakRatio = 0.1
    /// Allowed shortfall in delivered audio before we call it dropped.
    public var deliveryTolerance = 0.02
    public var maximumGapSeconds = 0.25

    public init() {}

    public func makeReport(
        me: (trace: ChannelTrace, info: ChannelInfo),
        them: (trace: ChannelTrace, info: ChannelInfo),
        phases: [SpikePhase],
        captureSeconds: Double,
        voiceProcessing: Bool,
        cpuPercentOfOneCore: Double?,
        osVersion: String,
        createdAt: Date = Date()
    ) -> SpikeReport {
        let meSummary = summarise(me.trace, info: me.info, captureSeconds: captureSeconds)
        let themSummary = summarise(them.trace, info: them.info, captureSeconds: captureSeconds)

        var phaseResults: [PhaseResult] = []
        for phase in phases {
            phaseResults.append(
                PhaseResult(
                    phase: phase,
                    me: phaseStats(me.trace, phase),
                    them: phaseStats(them.trace, phase)
                ))
        }

        let systemOnlyPhase = phases.first { !$0.expectMe && $0.expectThem }
        var bleedCorrelation: Double?
        if let systemOnlyPhase {
            bleedCorrelation = correlation(me.trace, them.trace, systemOnlyPhase)
        }

        var verdicts: [Verdict] = []
        verdicts.append(contentsOf: deliveryVerdicts(meSummary))
        verdicts.append(contentsOf: deliveryVerdicts(themSummary))
        for result in phaseResults {
            verdicts.append(contentsOf: phaseVerdicts(result))
        }

        return SpikeReport(
            createdAt: createdAt,
            osVersion: osVersion,
            voiceProcessing: voiceProcessing,
            captureSeconds: captureSeconds,
            cpuPercentOfOneCore: cpuPercentOfOneCore,
            channels: [meSummary, themSummary],
            phases: phaseResults,
            bleedCorrelation: bleedCorrelation,
            verdicts: verdicts
        )
    }

    func summarise(_ trace: ChannelTrace, info: ChannelInfo, captureSeconds: Double) -> ChannelSummary {
        let intervals = trace.chunkIntervals()
        var expected = 0
        if let first = trace.firstChunkOffset {
            expected = Int((captureSeconds - first) * Double(AudioChunk.sampleRate))
        }
        return ChannelSummary(
            info: info,
            samplesReceived: trace.sampleCount,
            samplesExpected: max(expected, 0),
            firstAudioAfterMs: trace.firstChunkOffset.map { $0 * 1000 },
            chunkCount: trace.chunkOffsets.count,
            chunkIntervalMeanMs: SpikeMath.mean(intervals).map { $0 * 1000 },
            chunkIntervalP95Ms: SpikeMath.percentile(intervals, 0.95).map { $0 * 1000 },
            longestGapMs: intervals.max().map { $0 * 1000 },
            allSamplesZero: !trace.sawNonZeroSample
        )
    }

    func phaseStats(_ trace: ChannelTrace, _ phase: SpikePhase) -> ChannelPhaseStats {
        let windows = trace.windows(from: phase.start, to: phase.end)
        var levels: [Double] = []
        var activeCount = 0
        for window in windows {
            levels.append(window.dbfs)
            if window.dbfs > activeThresholdDBFS {
                activeCount += 1
            }
        }
        let ratio = windows.isEmpty ? 0 : Double(activeCount) / Double(windows.count)
        return ChannelPhaseStats(meanDBFS: SpikeMath.powerMean(levels), activeRatio: ratio, windowCount: windows.count)
    }

    /// Lines the two channels up in 100 ms buckets and correlates their levels.
    func correlation(_ me: ChannelTrace, _ them: ChannelTrace, _ phase: SpikePhase) -> Double? {
        var themByBucket: [Int: Double] = [:]
        for window in them.windows(from: phase.start, to: phase.end) {
            themByBucket[bucket(window.endOffset)] = clampForCorrelation(window.dbfs)
        }
        var pairs: [(Double, Double)] = []
        for window in me.windows(from: phase.start, to: phase.end) {
            if let themLevel = themByBucket[bucket(window.endOffset)] {
                pairs.append((clampForCorrelation(window.dbfs), themLevel))
            }
        }
        return SpikeMath.pearson(pairs)
    }

    private func bucket(_ offset: Double) -> Int {
        Int((offset * 10).rounded(.down))
    }

    // Digital silence (-96) would otherwise dominate the correlation.
    private func clampForCorrelation(_ dbfs: Double) -> Double {
        max(dbfs, -80)
    }

    func deliveryVerdicts(_ summary: ChannelSummary) -> [Verdict] {
        let name = summary.info.speaker.rawValue
        var verdicts: [Verdict] = []

        if summary.chunkCount == 0 {
            verdicts.append(
                Verdict(
                    check: "\(name) channel delivers audio", passed: false,
                    detail: "no audio arrived at all"))
            return verdicts
        }
        if summary.allSamplesZero {
            let hint =
                summary.info.speaker == .me
                ? "microphone permission is probably denied"
                : "System Audio Recording permission is probably missing"
            verdicts.append(
                Verdict(
                    check: "\(name) channel delivers audio", passed: false,
                    detail: "every sample was zero, \(hint)"))
            return verdicts
        }

        let ratio = summary.deliveredRatio
        let longestGap = (summary.longestGapMs ?? 0) / 1000
        let continuous = abs(1 - ratio) <= deliveryTolerance && longestGap <= maximumGapSeconds
        verdicts.append(
            Verdict(
                check: "\(name) channel delivers a continuous stream",
                passed: continuous,
                detail: String(
                    format: "%.1f%% of expected samples, longest gap %.0f ms", ratio * 100, longestGap * 1000)
            ))
        return verdicts
    }

    func phaseVerdicts(_ result: PhaseResult) -> [Verdict] {
        var verdicts: [Verdict] = []
        let phase = result.phase
        let channels: [(Speaker, ChannelPhaseStats, Bool)] = [
            (.me, result.me, phase.expectMe),
            (.them, result.them, phase.expectThem),
        ]
        for (speaker, stats, expected) in channels {
            let detail = String(
                format: "active %.0f%% of the time, mean %.0f dBFS", stats.activeRatio * 100, stats.meanDBFS)
            if expected {
                verdicts.append(
                    Verdict(
                        check: "\(speaker.rawValue) is heard during \"\(phase.name)\"",
                        passed: stats.activeRatio >= minimumActiveRatio,
                        detail: detail
                    ))
            } else {
                verdicts.append(
                    Verdict(
                        check: "\(speaker.rawValue) stays quiet during \"\(phase.name)\"",
                        passed: stats.activeRatio <= maximumLeakRatio,
                        detail: detail + leakHint(speaker)
                    ))
            }
        }
        return verdicts
    }

    private func leakHint(_ speaker: Speaker) -> String {
        switch speaker {
        case .me:
            "; if this fails the mic is hearing the speakers: use headphones or try --voice-processing"
        case .them:
            "; if this fails something on the Mac was playing, or the tap is capturing the mic"
        }
    }
}
