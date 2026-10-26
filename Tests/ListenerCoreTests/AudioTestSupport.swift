import Foundation

@testable import ListenerCore

/// Test signals. Amplitudes are fractions of full scale.
enum Synth {
    static func tone(
        frequency: Double, seconds: Double, amplitude: Double = 0.3, rate: Int = AudioChunk.sampleRate
    ) -> [Int16] {
        let count = Int((seconds * Double(rate)).rounded())
        return (0..<count).map { index in
            Int16((amplitude * 32767 * sin(2 * Double.pi * frequency * Double(index) / Double(rate))).rounded())
        }
    }

    static func silence(seconds: Double, rate: Int = AudioChunk.sampleRate) -> [Int16] {
        [Int16](repeating: 0, count: Int((seconds * Double(rate)).rounded()))
    }

    /// A mono track of `seconds` with a tone wherever `bursts` say, digital silence elsewhere.
    static func track(
        seconds: Double, bursts: [ClosedRange<Double>], frequency: Double = 440, amplitude: Double = 0.3,
        rate: Int = AudioChunk.sampleRate
    ) -> [Int16] {
        var samples = silence(seconds: seconds, rate: rate)
        for burst in bursts {
            let start = Int((burst.lowerBound * Double(rate)).rounded())
            let end = min(Int((burst.upperBound * Double(rate)).rounded()), samples.count)
            for index in start..<end {
                let phase = 2 * Double.pi * frequency * Double(index) / Double(rate)
                samples[index] = Int16((amplitude * 32767 * sin(phase)).rounded())
            }
        }
        return samples
    }

    /// Typing: 15 ms bursts of noise at `levelDBFS`, `perSecond` of them give or take 30%
    /// of the interval, over a noise floor at -70 dBFS. The same for the same seed.
    static func keystrokes(seconds: Double, perSecond: Double, levelDBFS: Double, seed: UInt64 = 1) -> [Int16] {
        var random = SplitMix(state: seed)
        func gaussian() -> Double {
            let u = Double.random(in: Double.ulpOfOne..<1, using: &random)
            let v = Double.random(in: 0..<1, using: &random)
            return (-2 * log(u)).squareRoot() * cos(2 * Double.pi * v)
        }
        let rate = Double(AudioChunk.sampleRate)
        let floor = 32768 * pow(10, -70.0 / 20)
        var samples = (0..<Int(seconds * rate)).map { _ in gaussian() * floor }
        let amplitude = 32768 * pow(10, levelDBFS / 20)
        var time = 0.2
        while time < seconds {
            let start = Int(time * rate)
            for index in start..<min(start + Int(0.015 * rate), samples.count) {
                samples[index] += gaussian() * amplitude
            }
            time += Double.random(in: 0.7...1.3, using: &random) / perSecond
        }
        return samples.map { Int16(clamping: Int($0.rounded())) }
    }

    /// Two tracks played together, cut to the shorter.
    static func mix(_ first: [Int16], _ second: [Int16]) -> [Int16] {
        zip(first, second).map { Int16(clamping: Int($0) + Int($1)) }
    }

    static func interleave(_ channels: [[Int16]]) -> [Int16] {
        let frames = channels.map(\.count).min() ?? 0
        var samples: [Int16] = []
        samples.reserveCapacity(frames * channels.count)
        for frame in 0..<frames {
            for channel in channels {
                samples.append(channel[frame])
            }
        }
        return samples
    }

    /// Splits samples into chunks of the given sizes, cycling through them.
    static func split(_ samples: [Int16], sizes: [Int]) -> [ArraySlice<Int16>] {
        var parts: [ArraySlice<Int16>] = []
        var index = 0
        var sizeIndex = 0
        while index < samples.count {
            let end = min(index + sizes[sizeIndex % sizes.count], samples.count)
            parts.append(samples[index..<end])
            index = end
            sizeIndex += 1
        }
        return parts
    }
}

enum Measure {
    /// Amplitude (fraction of full scale) of the `frequency` component, by correlation
    /// with a sine and cosine over the whole signal.
    static func amplitude(of samples: ArraySlice<Int16>, at frequency: Double, rate: Int) -> Double {
        var sine = 0.0
        var cosine = 0.0
        for (offset, sample) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(offset) / Double(rate)
            let value = Double(sample) / 32767
            sine += value * sin(phase)
            cosine += value * cos(phase)
        }
        return 2 * (sine * sine + cosine * cosine).squareRoot() / Double(samples.count)
    }

    static func rms(_ samples: ArraySlice<Int16>) -> Double {
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(max(samples.count, 1))).squareRoot() / 32767
    }

    static func decibels(_ ratio: Double) -> Double {
        20 * log10(max(ratio, 1e-12))
    }
}

/// A WAV file in memory with any channel count, which WAVWriter (mono only) cannot make.
func wavData(_ interleaved: [Int16], sampleRate: Int, channelCount: Int) -> Data {
    var data = WAVHeader.make(sampleRate: sampleRate, channelCount: channelCount, dataByteCount: interleaved.count * 2)
    for sample in interleaved {
        data.appendLittleEndian(UInt16(bitPattern: sample))
    }
    return data
}

func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("listener-tests-\(UUID().uuidString)-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

extension Array where Element == Int16 {
    func chunks(of size: Int, speaker: Speaker = .them, start: ContinuousClock.Instant = .now) -> [AudioChunk] {
        var result: [AudioChunk] = []
        var index = 0
        while index < count {
            let end = Swift.min(index + size, count)
            let capturedAt = start + .seconds(Double(end) / Double(AudioChunk.sampleRate))
            result.append(AudioChunk(speaker: speaker, samples: Array(self[index..<end]), capturedAt: capturedAt))
            index = end
        }
        return result
    }
}
