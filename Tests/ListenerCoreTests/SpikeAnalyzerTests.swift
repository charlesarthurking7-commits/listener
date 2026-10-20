import Foundation
import Testing

@testable import ListenerCore

struct ChannelTraceTests {
    @Test func windowsAreCutEveryHundredMillisecondsAcrossChunks() {
        var trace = ChannelTrace()
        let chunk = [Int16](repeating: 1000, count: 1000)
        trace.append(chunk, atOffset: 0.0625)
        trace.append(chunk, atOffset: 0.125)
        trace.append(chunk, atOffset: 0.1875)

        #expect(trace.sampleCount == 3000)
        #expect(trace.windows.count == 1)
        #expect(trace.windows[0].endOffset == 0.125)
        #expect(trace.chunkIntervals() == [0.0625, 0.0625])
    }

    @Test func remembersWhetherAnythingButSilenceArrived() {
        var trace = ChannelTrace()
        trace.append([0, 0, 0], atOffset: 0)
        #expect(!trace.sawNonZeroSample)
        trace.append([0, 5, 0], atOffset: 0.1)
        #expect(trace.sawNonZeroSample)
    }

    @Test func liveLevelOnlyLooksAtRecentWindows() {
        var trace = ChannelTrace()
        trace.append(sine(amplitude: 0.5, count: 1600), atOffset: 0.1)
        trace.append([Int16](repeating: 0, count: 1600), atOffset: 1.1)
        #expect(trace.level(since: 1.0) == LevelMeter.floorDBFS)
        #expect(trace.level(since: 0.0) > -20)
    }
}

struct SpikeAnalyzerTests {
    let phases = SpikePhase.standard(secondsEach: 2)
    let meInfo = ChannelInfo(speaker: .me, backend: "test", device: "mic", nativeFormat: "48 kHz")
    let themInfo = ChannelInfo(speaker: .them, backend: "test", device: "tap", nativeFormat: "48 kHz")

    @Test func cleanSeparationPassesEveryCheck() {
        let me = simulate(activeDuring: [0, 2])
        let them = simulate(activeDuring: [1, 2])
        let report = makeReport(me: me, them: them)

        for verdict in report.verdicts {
            #expect(verdict.passed, "\(verdict.check): \(verdict.detail)")
        }
        #expect(report.allPassed)
        #expect(report.phases[0].me.activeRatio == 1)
        #expect(report.phases[0].them.activeRatio == 0)
    }

    @Test func audioBeforeTheFirstPhaseIsIgnored() {
        var me = ChannelTrace()
        var them = ChannelTrace()
        var offset = 0.0
        while offset < 7 - 1e-9 {
            offset += 0.1
            // One second of warm-up with sound on both channels, then the usual script.
            let phaseIndex = offset <= 1 ? -1 : Int((offset - 1) / 2 - 1e-9)
            let warmUp = phaseIndex == -1
            me.append(sine(amplitude: warmUp || phaseIndex != 1 ? 0.3 : 0.001, count: 1600), atOffset: offset)
            them.append(sine(amplitude: warmUp || phaseIndex != 0 ? 0.3 : 0.001, count: 1600), atOffset: offset)
        }
        let report = SpikeAnalyzer().makeReport(
            me: (me, meInfo),
            them: (them, themInfo),
            phases: SpikePhase.standard(secondsEach: 2, startingAt: 1),
            captureSeconds: 7,
            voiceProcessing: false,
            cpuPercentOfOneCore: nil,
            osVersion: "test"
        )
        #expect(report.phases[0].phase.start == 1)
        #expect(report.allPassed, "\(report.verdicts.filter { !$0.passed })")
    }

    @Test func speakerBleedFailsTheQuietMicCheck() {
        let me = simulate(activeDuring: [0, 1, 2])
        let them = simulate(activeDuring: [1, 2])
        let report = makeReport(me: me, them: them)

        let failed = report.verdicts.filter { !$0.passed }
        #expect(failed.count == 1)
        #expect(failed.first?.check == "Me stays quiet during \"system audio only\"")
    }

    @Test func allZeroChannelPointsAtPermissions() {
        let me = simulate(activeDuring: [0, 2])
        let them = simulate(activeDuring: [])
        let report = makeReport(me: me, them: them)

        let delivery = report.verdicts.first { $0.check.hasPrefix("Them channel delivers") }
        #expect(delivery?.passed == false)
        #expect(delivery?.detail.contains("System Audio Recording permission") == true)
    }

    @Test func droppedAudioFailsTheContinuityCheck() {
        var me = ChannelTrace()
        var offset = 0.0
        while offset < 6 {
            offset += 0.1
            // A one second hole in the middle, the kind of thing a stalled callback causes.
            if offset > 2.5 && offset < 3.5 {
                continue
            }
            me.append(sine(amplitude: 0.3, count: 1600), atOffset: offset)
        }
        let them = simulate(activeDuring: [1, 2])
        let report = makeReport(me: me, them: them)

        let continuity = report.verdicts.first { $0.check == "Me channel delivers a continuous stream" }
        #expect(continuity?.passed == false)
        #expect((report.channels[0].longestGapMs ?? 0) > 900)
    }

    @Test func bleedCorrelationIsHighWhenMicFollowsSpeakers() {
        var me = ChannelTrace()
        var them = ChannelTrace()
        var offset = 0.0
        var step = 0
        while offset < 6 {
            offset += 0.1
            step += 1
            let amplitude = step % 3 == 0 ? 0.6 : 0.05
            them.append(sine(amplitude: amplitude, count: 1600), atOffset: offset)
            me.append(sine(amplitude: amplitude / 10, count: 1600), atOffset: offset)
        }
        let report = makeReport(me: me, them: them)
        #expect((report.bleedCorrelation ?? 0) > 0.95)
    }

    @Test func reportSurvivesJSONRoundTrip() throws {
        let report = makeReport(me: simulate(activeDuring: [0, 2]), them: simulate(activeDuring: [1, 2]))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SpikeReport.self, from: report.jsonData())
        #expect(decoded.verdicts.count == report.verdicts.count)
        #expect(report.renderText().contains("[PASS]"))
    }

    /// 100 ms chunks for six seconds: speech-level sine in the listed phases, room noise otherwise.
    /// An empty list produces pure digital silence.
    private func simulate(activeDuring activePhases: [Int]) -> ChannelTrace {
        var trace = ChannelTrace()
        var offset = 0.0
        while offset < 6 - 1e-9 {
            offset += 0.1
            let phaseIndex = Int(offset / 2 - 1e-9)
            let samples: [Int16]
            if activePhases.isEmpty {
                samples = [Int16](repeating: 0, count: 1600)
            } else if activePhases.contains(phaseIndex) {
                samples = sine(amplitude: 0.3, count: 1600)
            } else {
                samples = sine(amplitude: 0.001, count: 1600)
            }
            trace.append(samples, atOffset: offset)
        }
        return trace
    }

    private func makeReport(me: ChannelTrace, them: ChannelTrace) -> SpikeReport {
        SpikeAnalyzer().makeReport(
            me: (me, meInfo),
            them: (them, themInfo),
            phases: phases,
            captureSeconds: 6,
            voiceProcessing: false,
            cpuPercentOfOneCore: 1.5,
            osVersion: "test"
        )
    }
}

struct SpikeRecorderTests {
    @Test func writesOneWAVPerChannelAndKeepsTraces() throws {
        let directory = temporaryFile("spike")
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = ContinuousClock.now
        let recorder = try SpikeRecorder(outputDirectory: directory, startedAt: start)
        recorder.record(AudioChunk(speaker: .me, samples: [1, 2, 3], capturedAt: start + .milliseconds(100)))
        recorder.record(AudioChunk(speaker: .them, samples: [4, 5], capturedAt: start + .milliseconds(200)))
        try recorder.finish()

        #expect(try WAVReader.read(url: directory.appendingPathComponent("me.wav")).samples == [1, 2, 3])
        #expect(try WAVReader.read(url: directory.appendingPathComponent("them.wav")).samples == [4, 5])
        let meOffset = try #require(recorder.trace(for: .me).firstChunkOffset)
        #expect(abs(meOffset - 0.1) < 1e-9)
    }
}
