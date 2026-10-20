import Foundation
import Synchronization

/// Collects both channels during the spike: writes each to its own WAV file and keeps
/// the traces the analysis needs. Capture callbacks arrive on different threads, so
/// all state sits behind one lock.
public final class SpikeRecorder: Sendable {
    private struct State {
        var traces: [Speaker: ChannelTrace] = [.me: ChannelTrace(), .them: ChannelTrace()]
        var writers: [Speaker: WAVWriter]
        var writeError: (any Error)?
    }

    private let state: Mutex<State>
    private let startedAt: ContinuousClock.Instant

    public init(outputDirectory: URL, startedAt: ContinuousClock.Instant) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var writers: [Speaker: WAVWriter] = [:]
        for speaker in Speaker.allCases {
            let url = outputDirectory.appendingPathComponent(Self.fileName(for: speaker))
            writers[speaker] = try WAVWriter(url: url, sampleRate: AudioChunk.sampleRate)
        }
        state = Mutex(State(writers: writers))
        self.startedAt = startedAt
    }

    public static func fileName(for speaker: Speaker) -> String {
        "\(speaker.rawValue.lowercased()).wav"
    }

    public func record(_ chunk: AudioChunk) {
        let offset = seconds(chunk.capturedAt - startedAt)
        state.withLock { state in
            state.traces[chunk.speaker]?.append(chunk.samples, atOffset: offset)
            if state.writeError != nil {
                return
            }
            do {
                try state.writers[chunk.speaker]?.append(chunk.samples)
            } catch {
                state.writeError = error
            }
        }
    }

    public func trace(for speaker: Speaker) -> ChannelTrace {
        state.withLock { $0.traces[speaker] ?? ChannelTrace() }
    }

    public func secondsSinceStart(_ now: ContinuousClock.Instant = .now) -> Double {
        seconds(now - startedAt)
    }

    /// Closes the WAV files. Throws the first write error seen during capture, if any.
    public func finish() throws {
        try state.withLock { state in
            for writer in state.writers.values {
                try writer.finish()
            }
            if let error = state.writeError {
                throw error
            }
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
