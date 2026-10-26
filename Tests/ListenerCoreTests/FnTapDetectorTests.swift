import Testing

@testable import ListenerCore

struct FnTapDetectorTests {
    /// Feeds (input, time) pairs and returns the taps they completed, in order.
    private func taps(_ inputs: [(FnTapDetector.Input, Double)], detector: inout FnTapDetector) -> [FnTapDetector.Tap] {
        inputs.compactMap { detector.handle($0.0, at: $0.1) }
    }

    private func taps(_ inputs: [(FnTapDetector.Input, Double)]) -> [FnTapDetector.Tap] {
        var detector = FnTapDetector()
        return taps(inputs, detector: &detector)
    }

    @Test func aQuickPressAndReleaseIsATap() {
        #expect(taps([(.fnDown, 0), (.fnUp, 0.1)]) == [.single])
    }

    @Test func twoQuickTapsAreADoubleTap() {
        #expect(taps([(.fnDown, 0), (.fnUp, 0.1), (.fnDown, 0.3), (.fnUp, 0.4)]) == [.single, .double])
    }

    @Test func tapsFarApartAreTwoSingleTaps() {
        #expect(taps([(.fnDown, 0), (.fnUp, 0.1), (.fnDown, 0.6), (.fnUp, 0.7)]) == [.single, .single])
    }

    @Test func holdingFnIsNotATap() {
        #expect(taps([(.fnDown, 0), (.fnUp, 0.5)]).isEmpty)
        // Nor can a hold be the first half of a double tap.
        #expect(taps([(.fnDown, 0), (.fnUp, 0.5), (.fnDown, 0.6), (.fnUp, 0.7)]) == [.single])
    }

    @Test func fnUsedAsAModifierIsNotATap() {
        // fn+Delete, then a tap straight after it.
        #expect(taps([(.fnDown, 0), (.otherKey, 0.05), (.fnUp, 0.1), (.fnDown, 0.3), (.fnUp, 0.4)]) == [.single])
    }

    @Test func typingBetweenTapsBreaksTheDoubleTap() {
        #expect(
            taps([(.fnDown, 0), (.fnUp, 0.1), (.otherKey, 0.2), (.fnDown, 0.3), (.fnUp, 0.4)]) == [.single, .single])
    }

    @Test func aThirdTapStraightAfterADoubleTapIsIgnored() {
        let inputs: [(FnTapDetector.Input, Double)] = [
            (.fnDown, 0), (.fnUp, 0.1), (.fnDown, 0.3), (.fnUp, 0.4), (.fnDown, 0.6), (.fnUp, 0.7),
        ]
        #expect(taps(inputs) == [.single, .double])
    }

    @Test func aTapAfterTheBurstCountsAgain() {
        let inputs: [(FnTapDetector.Input, Double)] = [
            (.fnDown, 0), (.fnUp, 0.1), (.fnDown, 0.3), (.fnUp, 0.4), (.fnDown, 2), (.fnUp, 2.1),
        ]
        #expect(taps(inputs) == [.single, .double, .single])
    }

    @Test func aSingleTapActedOnCannotStartADoubleTap() {
        // Dictating: the first tap of a double tap stops it, and the second must not start it again.
        var detector = FnTapDetector()
        #expect(taps([(.fnDown, 0), (.fnUp, 0.1)], detector: &detector) == [.single])
        detector.actedOnSingleTap()
        #expect(taps([(.fnDown, 0.3), (.fnUp, 0.4)], detector: &detector).isEmpty)
        #expect(
            taps([(.fnDown, 3), (.fnUp, 3.1), (.fnDown, 3.3), (.fnUp, 3.4)], detector: &detector) == [.single, .double])
    }

    @Test func theGlobeKeyPressMacOSSendsOnReleaseIsPartOfTheTap() {
        // What a MacBook sends for two taps: fn down, fn up, then Globe down at once.
        var detector = FnTapDetector()
        var seen: [FnTapDetector.Tap] = []
        for (time, isDown) in [(0.0, true), (0.09, false), (0.17, true), (0.29, false)] {
            if let tap = detector.handle(isDown ? .fnDown : .fnUp, at: time) {
                seen.append(tap)
            }
            if !isDown, let globe = FnTapDetector.input(forKeyDown: FnTapDetector.globeKeyCode) {
                _ = detector.handle(globe, at: time)
            }
        }
        #expect(seen == [.single, .double])
        #expect(FnTapDetector.input(forKeyDown: 51) == .otherKey)
    }

    @Test func aStrayTapJustAfterADoubleTapIsIgnored() {
        // The third tap of a slow double tap, half a second after it.
        #expect(
            taps([(.fnDown, 0), (.fnUp, 0.1), (.fnDown, 0.3), (.fnUp, 0.4), (.fnDown, 0.95), (.fnUp, 1.05)]) == [
                .single, .double,
            ])
    }

    @Test func aReleaseWithoutAPressIsIgnored() {
        #expect(taps([(.fnUp, 0.1)]).isEmpty)
    }
}
