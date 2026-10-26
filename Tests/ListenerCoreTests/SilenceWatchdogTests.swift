import Testing

@testable import ListenerCore

struct SilenceWatchdogTests {
    private let silent = AudioChunk(speaker: .them, samples: Array(repeating: 0, count: 1600), capturedAt: .now)
    private let audible = AudioChunk(speaker: .them, samples: Array(repeating: 3, count: 1600), capturedAt: .now)

    /// Feeds 100 ms silent chunks until the watchdog asks for a rebuild, and returns how
    /// many seconds of silence that took (nil if it never asked within `limit` seconds).
    private func secondsUntilDue(_ watchdog: inout SilenceWatchdog, limit: Int = 1000) -> Double? {
        for tenth in 1...(limit * 10) {
            if watchdog.observe(silent) {
                return Double(tenth) / 10
            }
        }
        return nil
    }

    @Test func asksForARebuildAfterTheTimeout() {
        var watchdog = SilenceWatchdog(timeout: .seconds(10))
        #expect(secondsUntilDue(&watchdog) == 10)
        #expect(watchdog.isDue)
    }

    @Test func aMutedCallWaitsLongerThanATapThatNeverHeardAnything() {
        // The other side muted while the user talks: exact zeros from a tap that worked.
        var watchdog = SilenceWatchdog(timeout: .seconds(10))
        _ = watchdog.observe(audible)
        #expect(secondsUntilDue(&watchdog) == 60)
        // A rebuilt tap has not proved itself yet.
        watchdog.rebuilt()
        #expect(secondsUntilDue(&watchdog) == 20)
    }

    @Test func asksOnlyOnceUntilToldWhatHappened() {
        var watchdog = SilenceWatchdog(timeout: .seconds(1))
        _ = secondsUntilDue(&watchdog)
        #expect(secondsUntilDue(&watchdog, limit: 30) == nil)
    }

    @Test func realAudioResetsTheCount() {
        var watchdog = SilenceWatchdog(timeout: .seconds(1))
        for _ in 0..<9 {
            _ = watchdog.observe(silent)
        }
        _ = watchdog.observe(audible)
        #expect(watchdog.silence == .zero)
        #expect(secondsUntilDue(&watchdog) == 60)
    }

    @Test func backsOffWhenRebuildingDoesNotHelp() {
        var watchdog = SilenceWatchdog(timeout: .seconds(10), maximumTimeout: .seconds(35))
        var waits: [Double?] = []
        for _ in 0..<4 {
            waits.append(secondsUntilDue(&watchdog))
            watchdog.rebuilt()
        }
        #expect(waits == [10, 20, 35, 35])
    }

    @Test func realAudioAfterARebuildClearsTheBackOff() {
        var watchdog = SilenceWatchdog(timeout: .seconds(2))
        _ = secondsUntilDue(&watchdog)
        watchdog.rebuilt()
        _ = secondsUntilDue(&watchdog)
        watchdog.rebuilt()
        #expect(watchdog.timeout == .seconds(8))

        _ = watchdog.observe(audible)
        #expect(watchdog.timeout == .seconds(2))
        #expect(secondsUntilDue(&watchdog) == 60)
    }

    @Test func explainedSilenceStartsOverWithoutBackingOff() {
        var watchdog = SilenceWatchdog(timeout: .seconds(3))
        _ = secondsUntilDue(&watchdog)
        watchdog.silenceExplained()
        #expect(!watchdog.isDue)
        #expect(secondsUntilDue(&watchdog) == 3)
    }

    @Test func maximumIsNeverBelowTheTimeout() {
        let watchdog = SilenceWatchdog(timeout: .seconds(30), maximumTimeout: .seconds(5))
        #expect(watchdog.maximumTimeout == .seconds(30))
    }
}
