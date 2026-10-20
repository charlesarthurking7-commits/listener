import Foundation
import Synchronization
import Testing

@testable import ListenerCore

/// Collects what a capture source delivers, from whatever thread it calls back on.
final class ChunkCollector: Sendable {
    private let chunks = Mutex<[AudioChunk]>([])

    var all: [AudioChunk] { chunks.withLock { $0 } }
    var samples: [Int16] { all.flatMap(\.samples) }

    func add(_ chunk: AudioChunk) {
        chunks.withLock { $0.append(chunk) }
    }
}

struct ReplaySourceTests {
    private func stereo48k(seconds: Double) -> WAVAudio {
        let left = Synth.tone(frequency: 500, seconds: seconds, amplitude: 0.5, rate: 48_000)
        let right = Synth.silence(seconds: seconds, rate: 48_000)
        return WAVAudio(sampleRate: 48_000, channelCount: 2, samples: Synth.interleave([left, right]))
    }

    @Test func unpacedPlaysTheWholeFileAsHundredMillisecondChunks() async throws {
        let source = try ReplaySource(
            audio: stereo48k(seconds: 2.03), speaker: .them, channel: .index(0), pacing: .unpaced)
        let collector = ChunkCollector()
        let info = try await source.start { collector.add($0) }
        await source.waitUntilFinished()

        #expect(
            info
                == ChannelInfo(
                    speaker: .them, backend: "replay", device: "in-memory audio",
                    nativeFormat: "48 kHz, 2 ch, int16, channel 0"))
        let chunks = collector.all
        #expect(chunks.allSatisfy { $0.speaker == .them })
        #expect(chunks.dropLast().allSatisfy { $0.samples.count == 1_600 })
        #expect(chunks.last?.samples.count == 480)
        #expect(collector.samples.count == 32_480)

        let amplitude = Measure.amplitude(of: collector.samples[1_000..<31_000], at: 500, rate: 16_000)
        #expect(abs(amplitude - 0.5) < 0.005)
        // Stamped at real-time pace even though delivered at once.
        let span = chunks.last!.capturedAt - chunks.first!.capturedAt
        #expect(abs(span.inSeconds - (32_480.0 - Double(chunks.first!.samples.count)) / 16_000) < 0.001)
    }

    @Test func picksOrMixesChannels() async throws {
        let audio = stereo48k(seconds: 0.5)
        func play(_ channel: ReplaySource.Channel) async throws -> [Int16] {
            let source = try ReplaySource(audio: audio, speaker: .me, channel: channel, pacing: .unpaced)
            let collector = ChunkCollector()
            _ = try await source.start { collector.add($0) }
            await source.waitUntilFinished()
            return collector.samples
        }
        let left = try await play(.index(0))
        let right = try await play(.index(1))
        let mixed = try await play(.mix)
        #expect(Measure.amplitude(of: left[500..<7_500], at: 500, rate: 16_000) > 0.49)
        #expect(right.allSatisfy { $0 == 0 })
        #expect(abs(Measure.amplitude(of: mixed[500..<7_500], at: 500, rate: 16_000) - 0.25) < 0.005)
    }

    @Test func pacesDeliveryByTheSpeedFactor() async throws {
        let audio = WAVAudio(sampleRate: 16_000, channelCount: 1, samples: Synth.silence(seconds: 2))
        let source = try ReplaySource(audio: audio, speaker: .me, pacing: .realTime(speed: 10))
        let collector = ChunkCollector()
        let started = ContinuousClock.now
        _ = try await source.start { collector.add($0) }
        await source.waitUntilFinished()
        let elapsed = (ContinuousClock.now - started).inSeconds

        // Only a lower bound: a busy test machine can always make it slower.
        #expect(elapsed >= 0.19)
        let chunks = collector.all
        #expect(chunks.count == 20)
        for (earlier, later) in zip(chunks, chunks.dropFirst()) {
            #expect(abs((later.capturedAt - earlier.capturedAt).inSeconds - 0.01) < 0.000_1)
        }
    }

    @Test func stopEndsPlaybackEarly() async throws {
        let audio = WAVAudio(sampleRate: 16_000, channelCount: 1, samples: Synth.silence(seconds: 30))
        let source = try ReplaySource(audio: audio, speaker: .me)
        let collector = ChunkCollector()
        _ = try await source.start { collector.add($0) }
        let deadline = ContinuousClock.now + .seconds(5)
        while collector.all.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        source.stop()
        await source.waitUntilFinished()
        let delivered = collector.samples.count
        #expect(delivered > 0)
        #expect(delivered < 30 * 16_000)
        try await Task.sleep(for: .milliseconds(150))
        #expect(collector.samples.count == delivered)
    }

    @Test func readsWAVFilesAtOtherRates() async throws {
        let directory = try temporaryDirectory("replay")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("call.wav")
        let tone = Synth.tone(frequency: 1_000, seconds: 1, amplitude: 0.4, rate: 44_100)
        try wavData(tone, sampleRate: 44_100, channelCount: 1).write(to: url)

        let source = try ReplaySource(url: url, speaker: .them, speed: 50)
        let collector = ChunkCollector()
        let info = try await source.start { collector.add($0) }
        await source.waitUntilFinished()
        #expect(info.device == "call.wav")
        #expect(info.nativeFormat == "44.1 kHz, 1 ch, int16")
        #expect(abs(source.duration - 1) < 1e-9)
        #expect(collector.samples.count == 16_000)
        #expect(abs(Measure.amplitude(of: collector.samples[500..<15_500], at: 1_000, rate: 16_000) - 0.4) < 0.004)
    }

    @Test func rejectsBadOptions() throws {
        let audio = stereo48k(seconds: 0.1)
        #expect(throws: ReplayError.noSuchChannel(2, channelCount: 2)) {
            try ReplaySource(audio: audio, speaker: .me, channel: .index(2))
        }
        #expect(throws: ReplayError.invalidSpeed(0)) {
            try ReplaySource(audio: audio, speaker: .me, pacing: .realTime(speed: 0))
        }
        let odd = WAVAudio(sampleRate: 16_001, channelCount: 1, samples: [0])
        #expect(throws: ResamplerError.unsupportedRate(16_001)) {
            try ReplaySource(audio: odd, speaker: .me)
        }
    }

    @Test func startingTwiceFails() async throws {
        let source = try ReplaySource(audio: stereo48k(seconds: 0.1), speaker: .me, pacing: .unpaced)
        _ = try await source.start { _ in }
        await #expect(throws: ReplayError.alreadyStarted) {
            _ = try await source.start { _ in }
        }
    }
}

extension Duration {
    var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
