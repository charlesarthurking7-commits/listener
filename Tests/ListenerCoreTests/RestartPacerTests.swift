import Testing

@testable import ListenerCore

struct BackoffTests {
    @Test func doublesUpToTheMaximum() {
        var backoff = Backoff(initial: .milliseconds(500), maximum: .seconds(3))
        let delays = (0..<6).map { _ in backoff.next() }
        #expect(delays == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(3), .seconds(3), .seconds(3)])
    }

    @Test func resetStartsOver() {
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(10))
        _ = backoff.next()
        _ = backoff.next()
        backoff.reset()
        #expect(backoff.next() == .seconds(1))
    }
}

struct RestartPacerTests {
    private let start = ContinuousClock.now

    @Test func firstRestartOnlyWaitsForDevicesToSettle() {
        var pacer = RestartPacer(settle: .milliseconds(300))
        #expect(pacer.delay(at: start) == .milliseconds(300))
    }

    @Test func restartsInQuickSuccessionBackOff() {
        var pacer = RestartPacer(
            settle: .milliseconds(300), backoff: Backoff(initial: .seconds(1), maximum: .seconds(4)),
            quietPeriod: .seconds(10))
        var now = start
        var delays: [Duration] = []
        for _ in 0..<5 {
            let delay = pacer.delay(at: now)
            delays.append(delay)
            now += delay
            pacer.restarted(at: now)
        }
        #expect(delays == [.milliseconds(300), .seconds(1), .seconds(2), .seconds(4), .seconds(4)])
    }

    @Test func aQuietSpellResetsTheBackoff() {
        var pacer = RestartPacer(settle: .milliseconds(300), quietPeriod: .seconds(10))
        pacer.restarted(at: start)
        #expect(pacer.delay(at: start + .seconds(1)) == .seconds(1))
        pacer.restarted(at: start + .seconds(2))
        #expect(pacer.delay(at: start + .seconds(30)) == .milliseconds(300))
        pacer.restarted(at: start + .seconds(30))
        #expect(pacer.delay(at: start + .seconds(31)) == .seconds(1))
    }

    @Test func neverWaitsLessThanTheSettleTime() {
        var pacer = RestartPacer(
            settle: .seconds(2), backoff: Backoff(initial: .milliseconds(100), maximum: .seconds(1)))
        pacer.restarted(at: start)
        #expect(pacer.delay(at: start + .milliseconds(10)) == .seconds(2))
    }
}
