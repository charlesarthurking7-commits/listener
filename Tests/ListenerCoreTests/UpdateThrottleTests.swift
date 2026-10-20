import Testing

@testable import ListenerCore

struct UpdateThrottleTests {
    @Test func theFirstChangeAfterAQuietSpellIsShownAtOnce() {
        var throttle = UpdateThrottle(interval: 0.016)
        #expect(throttle.request(at: 10) == .now)
        #expect(throttle.request(at: 10.5) == .now)
    }

    @Test func changesWithinAFrameAreCoalescedIntoOneUpdate() {
        var throttle = UpdateThrottle(interval: 0.016)
        #expect(throttle.request(at: 10) == .now)
        guard case .after(let delay) = throttle.request(at: 10.004) else {
            Issue.record("expected a scheduled update")
            return
        }
        #expect(abs(delay - 0.012) < 1e-9)
        #expect(throttle.request(at: 10.010) == .alreadyScheduled)

        throttle.didUpdate(at: 10.016)
        #expect(throttle.request(at: 10.020) != .now)
        throttle.didUpdate(at: 10.032)
        #expect(throttle.request(at: 10.060) == .now)
    }

    @Test func aDirectUpdateRestartsTheInterval() {
        var throttle = UpdateThrottle.displayRate
        throttle.didUpdate(at: 5)
        #expect(throttle.request(at: 5.001) != .now)
    }
}
