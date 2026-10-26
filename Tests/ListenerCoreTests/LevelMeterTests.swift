import Foundation
import Testing

@testable import ListenerCore

struct LevelMeterTests {
    @Test func fullScaleSquareWaveIsZeroDBFS() {
        let samples: [Int16] = [Int16.max, Int16.min, Int16.max, Int16.min]
        #expect(abs(LevelMeter.rmsDBFS(samples)) < 0.01)
    }

    @Test func sineWaveIsAboutMinusThreeDBFS() {
        let samples = Synth.tone(seconds: 1, amplitude: 1.0)
        #expect(abs(LevelMeter.rmsDBFS(samples) - (-3.01)) < 0.05)
    }

    @Test func halvingAmplitudeDropsSixDecibels() {
        let loud = LevelMeter.rmsDBFS(Synth.tone(seconds: 1, amplitude: 0.5))
        let quiet = LevelMeter.rmsDBFS(Synth.tone(seconds: 1, amplitude: 0.25))
        #expect(abs((loud - quiet) - 6.02) < 0.05)
    }

    @Test func silenceAndEmptyInputHitTheFloor() {
        #expect(LevelMeter.rmsDBFS([Int16](repeating: 0, count: 100)) == LevelMeter.floorDBFS)
        #expect(LevelMeter.rmsDBFS([Int16]()) == LevelMeter.floorDBFS)
        #expect(LevelMeter.isDigitalSilence([Int16](repeating: 0, count: 10)))
        #expect(!LevelMeter.isDigitalSilence([0, 0, 1]))
    }
}
