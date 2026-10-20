import Foundation
import Testing

@testable import ListenerCore

struct ResamplerTests {
    static let rates = [8_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]

    @Test(arguments: rates)
    func toneComesOutAtTheSameFrequencyAmplitudeAndPhase(rate: Int) throws {
        let frequency = 1_000.0
        let input = Synth.tone(frequency: frequency, seconds: 1, amplitude: 0.5, rate: rate)
        let output = try Resampler.resample(input, from: rate)
        let expected = Synth.tone(frequency: frequency, seconds: 1, amplitude: 0.5)
        #expect(output.count == expected.count)

        // Away from the edges, where the filter sees the zeros before and after.
        let middle = 400..<(expected.count - 400)
        let worst = middle.map { abs(Int(output[$0]) - Int(expected[$0])) }.max() ?? 0
        #expect(worst < 200, "worst sample error \(worst) at \(rate) Hz")
        let amplitude = Measure.amplitude(of: output[middle], at: frequency, rate: 16_000)
        #expect(abs(Measure.decibels(amplitude / 0.5)) < 0.1)
    }

    @Test(arguments: rates)
    func passbandIsFlat(rate: Int) throws {
        for frequency in [300.0, 3_000.0, min(5_500, Double(rate) * 0.4)] {
            let input = Synth.tone(frequency: frequency, seconds: 0.5, amplitude: 0.5, rate: rate)
            let output = try Resampler.resample(input, from: rate)
            let amplitude = Measure.amplitude(of: output[400..<(output.count - 400)], at: frequency, rate: 16_000)
            #expect(abs(Measure.decibels(amplitude / 0.5)) < 0.2, "\(frequency) Hz from \(rate) Hz")
        }
    }

    @Test(arguments: [22_050, 24_000, 32_000, 44_100, 48_000])
    func contentAbove8kHzIsRemovedNotAliased(rate: Int) throws {
        let nyquist = Double(rate) / 2
        for frequency in [8_500.0, 9_000.0, 10_000.0, 15_000.0] where frequency < nyquist * 0.98 {
            let input = Synth.tone(frequency: frequency, seconds: 0.5, amplitude: 0.5, rate: rate)
            let output = try Resampler.resample(input, from: rate)
            let level = Measure.rms(output[400..<(output.count - 400)])
            #expect(Measure.decibels(level / 0.5) < -60, "\(frequency) Hz from \(rate) Hz leaked")
        }
    }

    @Test func upsamplingDoesNotCreateImages() throws {
        let input = Synth.tone(frequency: 1_000, seconds: 0.5, amplitude: 0.5, rate: 8_000)
        let output = try Resampler.resample(input, from: 8_000)
        let image = Measure.amplitude(of: output[400..<(output.count - 400)], at: 7_000, rate: 16_000)
        #expect(Measure.decibels(image / 0.5) < -60)
    }

    @Test(arguments: [8_000, 22_050, 44_100, 48_000])
    func streamingMatchesOneShot(rate: Int) throws {
        let input = Synth.tone(frequency: 700, seconds: 0.7, amplitude: 0.4, rate: rate)
        let whole = try Resampler.resample(input, from: rate)
        var resampler = try Resampler(inputRate: rate)
        var streamed: [Int16] = []
        for part in Synth.split(input, sizes: [1, 441, 4_800, 13, 1_000]) {
            streamed += resampler.process(Array(part))
        }
        streamed += resampler.flush()
        #expect(streamed == whole)
    }

    @Test func sixteenKilohertzMonoIsUntouched() throws {
        let input = Synth.tone(frequency: 7_900, seconds: 0.1, amplitude: 0.9)
        #expect(try Resampler.resample(input, from: 16_000) == input)
    }

    @Test func interleavedChannelsAreAveraged() throws {
        let left = Synth.tone(frequency: 1_000, seconds: 0.5, amplitude: 0.6, rate: 48_000)
        let silent = Synth.silence(seconds: 0.5, rate: 48_000)
        let half = try Resampler.resample(Synth.interleave([left, silent]), from: 48_000, channelCount: 2)
        let amplitude = Measure.amplitude(of: half[400..<(half.count - 400)], at: 1_000, rate: 16_000)
        #expect(abs(amplitude - 0.3) < 0.003)

        let inverted = left.map { $0 == .min ? .max : -$0 }
        let cancelled = try Resampler.resample(Synth.interleave([left, inverted]), from: 48_000, channelCount: 2)
        #expect(cancelled.allSatisfy { abs(Int($0)) <= 1 })

        let stereoAt16k = try Resampler.resample(
            Synth.interleave([[100, 200], [300, 400]]), from: 16_000, channelCount: 2)
        #expect(stereoAt16k == [200, 300])
    }

    @Test func outputLengthFollowsTheRateRatio() throws {
        for (rate, count, expected) in [(48_000, 4_800, 1_600), (44_100, 4_410, 1_600), (44_100, 1, 1), (8_000, 3, 6)] {
            let output = try Resampler.resample([Int16](repeating: 0, count: count), from: rate)
            #expect(output.count == expected, "\(count) samples at \(rate) Hz")
        }
    }

    @Test func rejectsUnusableFormats() {
        #expect(throws: ResamplerError.invalidChannelCount(0)) { try Resampler(inputRate: 48_000, channelCount: 0) }
        #expect(throws: ResamplerError.unsupportedRate(0)) { try Resampler(inputRate: 0) }
        // 16,001 Hz would need 16,000 filter phases.
        #expect(throws: ResamplerError.unsupportedRate(16_001)) { try Resampler(inputRate: 16_001) }
    }
}
