import Foundation

public enum ResamplerError: Error, Equatable {
    case unsupportedRate(Int)
    case invalidChannelCount(Int)
}

/// Converts 16-bit PCM at any common capture or file rate (8, 16, 22.05, 24, 32, 44.1,
/// 48 kHz and so on) to 16 kHz, averaging interleaved channels down to mono first.
///
/// A polyphase windowed-sinc filter: the rate ratio is reduced to L/M, and for each
/// output sample one of L precomputed tap sets is applied to the input around it. The
/// cutoff sits at 90% of the lower Nyquist frequency with a Kaiser window, so content
/// above 8 kHz is removed (better than 70 dB) instead of folding back as aliasing.
///
/// Streaming: feed chunks of any size to `process`, then call `flush` once at the end.
/// The output is the same however the input was split.
public struct Resampler: Sendable {
    public let inputRate: Int
    public let outputRate: Int
    public let channelCount: Int

    private let upFactor: Int
    private let downFactor: Int
    private let halfWidth: Int
    private let taps: [Float]
    private let passthrough: Bool

    // Mono input still needed. history[0] is input sample number `historyStart`, which
    // starts negative because the filter looks before the first sample (zeros).
    private var history: [Float] = []
    private var historyStart: Int
    private var inputCount = 0
    private var outputCount = 0

    /// Zero crossings of the sinc kept on each side of the centre tap. With the Kaiser
    /// window below this gives a stopband from the output Nyquist frequency onwards.
    private static let zeroCrossings = 24.0
    private static let kaiserBeta = 8.0
    private static let cutoffFraction = 0.9
    private static let maximumPhases = 4096

    public init(inputRate: Int, channelCount: Int = 1, outputRate: Int = AudioChunk.sampleRate) throws {
        guard channelCount > 0 else {
            throw ResamplerError.invalidChannelCount(channelCount)
        }
        guard inputRate > 0, outputRate > 0 else {
            throw ResamplerError.unsupportedRate(inputRate)
        }
        let divisor = greatestCommonDivisor(inputRate, outputRate)
        let up = outputRate / divisor
        guard up <= Self.maximumPhases else {
            throw ResamplerError.unsupportedRate(inputRate)
        }

        self.inputRate = inputRate
        self.outputRate = outputRate
        self.channelCount = channelCount
        upFactor = up
        downFactor = inputRate / divisor
        passthrough = inputRate == outputRate

        let cutoff = Self.cutoffFraction * min(1, Double(outputRate) / Double(inputRate))
        halfWidth = passthrough ? 0 : Int((Self.zeroCrossings / cutoff).rounded(.up))
        taps = passthrough ? [] : Self.makeTaps(phases: up, halfWidth: halfWidth, cutoff: cutoff)
        historyStart = -max(halfWidth - 1, 0)
        history = [Float](repeating: 0, count: max(halfWidth - 1, 0))
    }

    /// Resamples a whole recording in one go.
    public static func resample(_ interleaved: [Int16], from inputRate: Int, channelCount: Int = 1) throws -> [Int16] {
        var resampler = try Resampler(inputRate: inputRate, channelCount: channelCount)
        return resampler.process(interleaved) + resampler.flush()
    }

    /// Resamples the next stretch of interleaved input. Trailing samples of an
    /// incomplete multi-channel frame are ignored.
    public mutating func process(_ interleaved: [Int16]) -> [Int16] {
        if passthrough {
            return channelCount == 1 ? interleaved : downmix(interleaved).map(clamp)
        }
        let mono = downmix(interleaved)
        inputCount += mono.count
        history.append(contentsOf: mono)
        return produce(limit: nil)
    }

    /// Emits the last samples, treating the input as followed by silence. Call once,
    /// after the last `process`.
    public mutating func flush() -> [Int16] {
        if passthrough {
            return []
        }
        // Every output sample whose position falls inside the input is due.
        let total = (inputCount * upFactor + downFactor - 1) / downFactor
        history.append(contentsOf: repeatElement(0, count: halfWidth + 1))
        return produce(limit: total)
    }

    private mutating func produce(limit: Int?) -> [Int16] {
        let width = 2 * halfWidth
        let available = historyStart + history.count
        let (up, down, half, start) = (upFactor, downFactor, halfWidth, historyStart)
        var next = outputCount
        var output: [Int16] = []
        output.reserveCapacity(max(0, (available - half) * up / down - next + 1))
        taps.withUnsafeBufferPointer { taps in
            history.withUnsafeBufferPointer { history in
                while next < limit ?? Int.max {
                    let position = next * down
                    let centre = position / up
                    if centre + half >= available {
                        break
                    }
                    let tapBase = (position - centre * up) * width
                    let first = centre - half + 1 - start
                    var sum: Float = 0
                    for k in 0..<width {
                        sum += taps[tapBase + k] * history[first + k]
                    }
                    output.append(clamp(sum))
                    next += 1
                }
            }
        }
        outputCount = next

        // Drop input that no future output sample reaches back to.
        let firstNeeded = outputCount * downFactor / upFactor - halfWidth + 1
        let unused = min(firstNeeded - historyStart, history.count)
        if unused > 0 {
            history.removeFirst(unused)
            historyStart += unused
        }
        return output
    }

    private func downmix(_ interleaved: [Int16]) -> [Float] {
        if channelCount == 1 {
            return interleaved.map(Float.init)
        }
        let frames = interleaved.count / channelCount
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channelCount)
        interleaved.withUnsafeBufferPointer { samples in
            for frame in 0..<frames {
                var sum: Float = 0
                let base = frame * channelCount
                for channel in 0..<channelCount {
                    sum += Float(samples[base + channel])
                }
                mono[frame] = sum * scale
            }
        }
        return mono
    }

    /// Tap sets for each of `phases` fractional positions, phase-major. Each set is
    /// normalised to a gain of exactly 1 at DC.
    private static func makeTaps(phases: Int, halfWidth: Int, cutoff: Double) -> [Float] {
        let width = 2 * halfWidth
        let windowNorm = besselI0(kaiserBeta)
        var taps = [Float](repeating: 0, count: phases * width)
        var phaseTaps = [Double](repeating: 0, count: width)
        for phase in 0..<phases {
            let fraction = Double(phase) / Double(phases)
            var sum = 0.0
            for k in 0..<width {
                // Distance from the output position to input sample `centre - halfWidth + 1 + k`.
                let distance = Double(k - halfWidth + 1) - fraction
                let ratio = distance / Double(halfWidth)
                let window = abs(ratio) >= 1 ? 0 : besselI0(kaiserBeta * (1 - ratio * ratio).squareRoot()) / windowNorm
                let value = cutoff * sinc(cutoff * distance) * window
                phaseTaps[k] = value
                sum += value
            }
            for k in 0..<width {
                taps[phase * width + k] = Float(phaseTaps[k] / sum)
            }
        }
        return taps
    }
}

private func clamp(_ value: Float) -> Int16 {
    Int16(max(-32768, min(32767, value.rounded())))
}

private func sinc(_ x: Double) -> Double {
    if abs(x) < 1e-12 {
        return 1
    }
    let angle = Double.pi * x
    return sin(angle) / angle
}

/// Modified Bessel function of the first kind, order 0, for the Kaiser window.
private func besselI0(_ x: Double) -> Double {
    var sum = 1.0
    var term = 1.0
    let quarterSquare = x * x / 4
    var k = 1.0
    while term > sum * 1e-12 {
        term *= quarterSquare / (k * k)
        sum += term
        k += 1
    }
    return sum
}

private func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
    var (a, b) = (a, b)
    while b != 0 {
        (a, b) = (b, a % b)
    }
    return a
}
