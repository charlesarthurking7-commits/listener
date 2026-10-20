import Synchronization

/// Hands one channel's audio to its consumer as a single unbroken stream.
///
/// Capture sources call `accept(_:)` from their own threads and a background tick fills
/// silence while they deliver nothing (see GapFiller), so the consumer keeps receiving
/// audio across device changes and rebuilds. Chunks reach `onChunk` in order, one at a
/// time, and never after `stop()` returns. That lets a source tear its hardware down
/// asynchronously without the consumer seeing stray audio afterwards.
///
/// `onChunk` runs while the feed holds its lock, so it must not call back into the feed.
public final class ContinuousAudioFeed: Sendable {
    private struct State {
        var filler: GapFiller?
        var ticker: Task<Void, Never>?
        var stopped = false
    }

    public let speaker: Speaker
    private let threshold: Duration
    private let tickInterval: Duration
    private let onChunk: @Sendable (AudioChunk) -> Void
    private let state = Mutex(State())

    public init(
        speaker: Speaker,
        threshold: Duration = GapFiller.defaultThreshold,
        tickInterval: Duration = .milliseconds(100),
        onChunk: @escaping @Sendable (AudioChunk) -> Void
    ) {
        self.speaker = speaker
        self.threshold = threshold
        self.tickInterval = tickInterval
        self.onChunk = onChunk
    }

    deinit {
        state.withLock { $0.ticker?.cancel() }
    }

    /// Starts the channel's clock at `origin` and the tick that fills silence.
    public func start(at origin: ContinuousClock.Instant = .now) {
        state.withLock { state in
            if state.filler != nil || state.stopped {
                return
            }
            state.filler = GapFiller(speaker: speaker, origin: origin, threshold: threshold)
            state.ticker = Task { [weak self, tickInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: tickInterval)
                    guard let self else {
                        return
                    }
                    self.tick(now: .now)
                }
            }
        }
    }

    /// Takes a converted chunk from the capture source. Ignored before `start` and after `stop`.
    public func accept(_ chunk: AudioChunk) {
        state.withLock { state in
            if state.stopped {
                return
            }
            for piece in state.filler?.accept(chunk) ?? [] {
                onChunk(piece)
            }
        }
    }

    /// Tells the feed the source just rebuilt its capture path, so that even a short break
    /// is filled and the channel stays in step with the wall clock (see GapFiller).
    public func realign() {
        state.withLock { $0.filler?.realign() }
    }

    /// Ends delivery. Once this returns, `onChunk` is never called again.
    public func stop() {
        let ticker = state.withLock { state in
            state.stopped = true
            defer { state.ticker = nil }
            return state.ticker
        }
        ticker?.cancel()
    }

    func tick(now: ContinuousClock.Instant) {
        state.withLock { state in
            if state.stopped {
                return
            }
            for piece in state.filler?.fill(until: now) ?? [] {
                onChunk(piece)
            }
        }
    }
}
