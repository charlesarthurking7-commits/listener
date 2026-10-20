import Testing

@testable import ListenerCore

struct AudioRouteTests {
    private let route = AudioRoute(
        outputDeviceUID: "BuiltInSpeakers", outputSampleRate: 48_000, captureSampleRate: 48_000)

    @Test func sameRouteNeedsNoRebuild() {
        #expect(route.restartReason(movingTo: route) == nil)
    }

    @Test func newOutputDeviceNeedsARebuild() {
        var headset = route
        headset.outputDeviceUID = "AirPods"
        #expect(route.restartReason(movingTo: headset) == .outputDeviceChanged)
    }

    @Test func losingTheOutputDeviceNeedsARebuild() {
        var none = route
        none.outputDeviceUID = nil
        #expect(route.restartReason(movingTo: none) == .outputDeviceChanged)
    }

    @Test func sampleRateChangeOnEitherSideNeedsARebuild() {
        var callProfile = route
        callProfile.outputSampleRate = 24_000
        #expect(route.restartReason(movingTo: callProfile) == .sampleRateChanged)

        var aggregate = route
        aggregate.captureSampleRate = 44_100
        #expect(route.restartReason(movingTo: aggregate) == .sampleRateChanged)
    }

    @Test func unreadableRateIsNotAChange() {
        var reconfiguring = route
        reconfiguring.outputSampleRate = nil
        reconfiguring.captureSampleRate = nil
        #expect(route.restartReason(movingTo: reconfiguring) == nil)
    }
}

struct CaptureEventTests {
    @Test func describesEventsForTheLog() {
        #expect(
            CaptureEvent.restarted(.them, reason: .outputDeviceChanged).description
                == "Them: capture restarted (output device changed).")
        #expect(
            CaptureEvent.restartFailed(.me, reason: .inputDeviceChanged, error: "no mic", retryIn: .milliseconds(1500))
                .description
                == "Me: capture restart after input device changed failed: no mic. "
                + "Retrying in 1.5 s, sending silence meanwhile.")
        #expect(
            CaptureEvent.restarted(.them, reason: .digitalSilence(seconds: 10)).description
                == "Them: capture restarted (10 s of digital silence while audio was playing).")
        #expect(CaptureEvent.stoppedByUser(.them).description == "Them: capture was stopped from outside Listener.")
    }

    @Test func wholeSecondsHaveNoDecimals() {
        let event = CaptureEvent.restartFailed(.them, reason: .streamStopped, error: "x", retryIn: .seconds(4))
        #expect(event.description.contains("Retrying in 4 s,"))
    }
}
