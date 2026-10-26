import Testing

@testable import ListenerCore

struct DeliveredRateMonitorTests {
    /// Buffers of `frames` frames arriving at `rate` from `start` for `seconds`, and what
    /// the monitor reported about them.
    private func deliver(
        to monitor: inout DeliveredRateMonitor, rate: Double, frames: Int = 512, from start: Double = 100,
        seconds: Double = 4
    ) -> [DeliveredRateMonitor.Outcome] {
        let interval = Double(frames) / rate
        var outcomes: [DeliveredRateMonitor.Outcome] = []
        var time = start
        while time < start + seconds {
            if let outcome = monitor.record(frames: frames, at: time) {
                outcomes.append(outcome)
            }
            time += interval
        }
        return outcomes
    }

    private func measured(_ outcome: DeliveredRateMonitor.Outcome?) -> Double? {
        switch outcome {
        case .matches(let measured), .corrected(_, _, let measured), .unexplained(let measured): measured
        case nil: nil
        }
    }

    private func corrections(_ outcomes: [DeliveredRateMonitor.Outcome]) -> [Double] {
        outcomes.compactMap { if case .corrected(_, let to, _) = $0 { to } else { nil } }
    }

    /// 48 kHz in 10.7 ms cycles of which every `dropEvery`th is lost, as under heavy load,
    /// with Core Audio's sample time for each buffer that does arrive.
    private func deliverDroppingCycles(
        to monitor: inout DeliveredRateMonitor, rate: Double, dropEvery: Int, sampleTimes: Bool
    ) -> [DeliveredRateMonitor.Outcome] {
        let frames = 512
        var outcomes: [DeliveredRateMonitor.Outcome] = []
        for cycle in 0..<Int(10 * rate / Double(frames)) where cycle % dropEvery != 0 {
            let sampleTime = Double(cycle * frames)
            let time = 100 + sampleTime / rate
            if let outcome = monitor.record(frames: frames, at: time, sampleTime: sampleTimes ? sampleTime : nil) {
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    @Test func cyclesLostUnderLoadDoNotReadAsALowerRate() {
        // Counting frames, losing one cycle in twelve reads 48 kHz as about 44 kHz.
        var counting = DeliveredRateMonitor(rate: 48_000)
        let counted = deliverDroppingCycles(to: &counting, rate: 48_000, dropEvery: 12, sampleTimes: false)
        #expect(corrections(counted) == [44_100])
        // The device's sample time counts the lost frames too.
        var timed = DeliveredRateMonitor(rate: 48_000)
        let outcomes = deliverDroppingCycles(to: &timed, rate: 48_000, dropEvery: 12, sampleTimes: true)
        #expect(corrections(outcomes).isEmpty)
        #expect(timed.rate == 48_000)
    }

    @Test func aTapThatRunsAtHalfItsStatedRateIsStillCaughtBySampleTime() {
        // AirPods in call mode: the aggregate's clock, and so its sample time, runs at 24 kHz.
        var monitor = DeliveredRateMonitor(rate: 48_000)
        let outcomes = deliverDroppingCycles(to: &monitor, rate: 24_000, dropEvery: 1_000_000, sampleTimes: true)
        #expect(corrections(outcomes) == [24_000])
    }

    @Test func deliveryAtTheReadRateMatchesOnce() throws {
        var monitor = DeliveredRateMonitor(rate: 48_000)
        let outcomes = deliver(to: &monitor, rate: 48_000, seconds: 20)
        #expect(outcomes.count == 1)
        guard case .matches(let rate) = try #require(outcomes.first) else {
            Issue.record("Expected a match, got \(outcomes)")
            return
        }
        #expect(abs(rate - 48_000) < 1)
        #expect(monitor.rate == 48_000)
    }

    @Test func halfRateDeliveryIsReadAtTheRateItArrivesAt() {
        var monitor = DeliveredRateMonitor(rate: 48_000)
        let outcomes = deliver(to: &monitor, rate: 24_000, frames: 480, seconds: 10)
        #expect(corrections(outcomes) == [24_000])
        #expect(outcomes.count == 1)
        #expect(monitor.rate == 24_000)
    }

    @Test func otherStandardRatesAreCorrectedToo() {
        var monitor = DeliveredRateMonitor(rate: 48_000)
        #expect(corrections(deliver(to: &monitor, rate: 44_100, frames: 441)) == [44_100])
    }

    @Test func aSwitchMidCallIsCaughtEachWay() {
        // Start before joining: normal 48 kHz, then call mode, then the call ends.
        var monitor = DeliveredRateMonitor(rate: 48_000)
        var outcomes = deliver(to: &monitor, rate: 48_000, from: 100, seconds: 30)
        outcomes += deliver(to: &monitor, rate: 24_000, frames: 480, from: 130, seconds: 60)
        outcomes += deliver(to: &monitor, rate: 48_000, from: 190, seconds: 30)
        #expect(corrections(outcomes) == [24_000, 48_000])
        guard case .matches = outcomes.first else {
            Issue.record("Expected the first outcome to be a match, got \(outcomes)")
            return
        }
    }

    @Test func aSwitchIsCaughtWithinAFewSeconds() throws {
        var monitor = DeliveredRateMonitor(rate: 48_000)
        _ = deliver(to: &monitor, rate: 48_000, from: 100, seconds: 10)
        var time = 110.0
        var caughtAt: Double?
        while time < 130, caughtAt == nil {
            if case .corrected = monitor.record(frames: 480, at: time) {
                caughtAt = time
            }
            time += 480 / 24_000
        }
        #expect(try #require(caughtAt) - 110 < 4)
    }

    @Test func aSpanStraddlingASwitchIsNotActedOn() {
        // Spans that mix 48 kHz and 24 kHz can read near 32 kHz, a standard rate.
        for offset in stride(from: 0.0, to: 1.0, by: 0.05) {
            var monitor = DeliveredRateMonitor(rate: 48_000)
            var outcomes = deliver(to: &monitor, rate: 48_000, from: 100, seconds: 5 + offset)
            outcomes += deliver(to: &monitor, rate: 24_000, frames: 480, from: 105 + offset, seconds: 10)
            #expect(corrections(outcomes) == [24_000], "offset \(offset)")
        }
    }

    @Test func aStallStartsTheMeasurementAgain() throws {
        var monitor = DeliveredRateMonitor(rate: 48_000)
        #expect(deliver(to: &monitor, rate: 48_000, from: 100, seconds: 1.5).isEmpty)
        // A second with nothing delivered would read as a third off the rate.
        let outcomes = deliver(to: &monitor, rate: 48_000, from: 102.5, seconds: 4)
        #expect(outcomes.count == 1)
        let rate = try #require(measured(outcomes.first))
        #expect(abs(rate - 48_000) < 1)
    }

    @Test func aBurstAtTheStartIsSkipped() throws {
        func burstThenSteady(warmUp: Double) -> [DeliveredRateMonitor.Outcome] {
            var monitor = DeliveredRateMonitor(rate: 48_000, warmUp: warmUp)
            for _ in 0..<40 {
                _ = monitor.record(frames: 512, at: 100)
            }
            return deliver(to: &monitor, rate: 48_000, from: 100.01, seconds: 4)
        }
        let skipped = try #require(measured(burstThenSteady(warmUp: 0.5).first))
        #expect(abs(skipped - 48_000) < 1)
        // Counted, the burst makes the first span disagree with the next, so nothing is
        // corrected on the strength of it.
        #expect(corrections(burstThenSteady(warmUp: 0)).isEmpty)
    }

    @Test func aRateNoDeviceRunsAtIsLeftAloneAndReportedOnce() {
        var monitor = DeliveredRateMonitor(rate: 48_000)
        let outcomes = deliver(to: &monitor, rate: 37_000, seconds: 20)
        #expect(outcomes.map { if case .unexplained = $0 { true } else { false } } == [true])
        #expect(monitor.rate == 48_000)
    }
}
