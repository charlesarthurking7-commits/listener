import Testing

@testable import ListenerCore

struct CaptureClockTests {
    @Test func emptyClockIsTheIdentity() {
        #expect(CaptureClock().sessionTime(at: 3.5) == 3.5)
    }

    @Test func interpolatesBetweenFrames() {
        var clock = CaptureClock()
        clock.record(audio: 0, session: 10)
        clock.record(audio: 0.1, session: 10.1)
        clock.record(audio: 0.2, session: 10.3)
        #expect(near(clock.sessionTime(at: 0.05), 10.05))
        #expect(near(clock.sessionTime(at: 0.15), 10.2))
        #expect(near(clock.sessionTime(at: 0.2), 10.3))
    }

    @Test func followsAnyRate() {
        var clock = CaptureClock()
        for index in 0...20 {
            clock.record(audio: Double(index) / 10, session: Double(index) / 80)
        }
        #expect(near(clock.sessionTime(at: 1.6), 0.2))
        #expect(near(clock.sessionTime(at: 0.73), 0.73 / 8))
    }

    @Test func extrapolatesAtRealTimeOutsideTheRecordedSpan() {
        var clock = CaptureClock()
        clock.record(audio: 1, session: 5)
        clock.record(audio: 2, session: 5.5)
        #expect(near(clock.sessionTime(at: 0.5), 4.5))
        #expect(near(clock.sessionTime(at: 3), 6.5))
    }

    @Test func ignoresPointsThatGoBackwards() {
        var clock = CaptureClock()
        clock.record(audio: 1, session: 1)
        clock.record(audio: 1, session: 9)
        clock.record(audio: 0.5, session: 9)
        #expect(clock.sessionTime(at: 2) == 2)
    }

    @Test func keepsOnlyRecentFrames() {
        var clock = CaptureClock(capacity: 10)
        for index in 0..<25 {
            // A one-off jump of 100 s at frame 5, long forgotten by the end.
            clock.record(audio: Double(index), session: Double(index) + (index >= 5 ? 100 : 0))
        }
        #expect(near(clock.sessionTime(at: 20.5), 120.5))
        #expect(near(clock.sessionTime(at: 2), 102))
    }
}
