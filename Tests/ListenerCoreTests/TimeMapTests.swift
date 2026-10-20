import Testing

@testable import ListenerCore

struct TimeMapTests {
    @Test func emptyMapIsTheIdentity() {
        #expect(TimeMap(tolerance: 0.05).map(12.5) == 12.5)
    }

    @Test func appliesTheOffsetOfTheLatestAnchor() {
        var map = TimeMap(tolerance: 0.05)
        map.record(from: 0, to: 2)
        map.record(from: 1, to: 3.01)
        map.record(from: 5, to: 10)
        #expect(map.map(0.5) == 2.5)
        #expect(map.map(4.9) == 6.9)
        #expect(map.map(5) == 10)
        #expect(map.map(6.25) == 11.25)
        #expect(map.map(-1) == 1)
    }

    @Test func anEndAtAJumpBelongsToTheStretchBeforeIt() {
        var map = TimeMap(tolerance: 0.001)
        map.record(from: 0, to: 0)
        map.record(from: 0.3, to: 5)
        #expect(map.map(0.3) == 5)
        #expect(map.mapEnd(0.3) == 0.3)
        #expect(map.mapEnd(0.4) == map.map(0.4))
        #expect(map.mapEnd(0.2) == 0.2)
        #expect(map.mapEnd(-1) == -1)
        #expect(TimeMap(tolerance: 0.001).mapEnd(3) == 3)
    }

    @Test func jitterWithinToleranceAddsNoAnchor() {
        var jittery = TimeMap(tolerance: 0.05)
        var single = TimeMap(tolerance: 0.05)
        single.record(from: 0, to: 1.03)
        for step in 0..<100 {
            let from = Double(step) * 0.1
            jittery.record(from: from, to: from + 1 + (step.isMultiple(of: 2) ? 0.03 : -0.01))
        }
        #expect(jittery == single)
        #expect(jittery.map(7.3) == 7.3 + 1.03)
    }

    @Test func pointsGoingBackwardsAreIgnored() {
        var map = TimeMap(tolerance: 0.001)
        map.record(from: 1, to: 1)
        map.record(from: 1, to: 5)
        map.record(from: 0.5, to: 9)
        #expect(map.map(2) == 2)
    }
}
