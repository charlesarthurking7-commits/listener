import Foundation
import Testing

@testable import ListenerCore

struct LevelMeterTests {
    @Test func fullScaleSquareWaveIsZeroDBFS() {
        let samples: [Int16] = [Int16.max, Int16.min, Int16.max, Int16.min]
        #expect(abs(LevelMeter.rmsDBFS(samples)) < 0.01)
    }

    @Test func sineWaveIsAboutMinusThreeDBFS() {
        let samples = sine(amplitude: 1.0, count: 16_000)
        #expect(abs(LevelMeter.rmsDBFS(samples) - (-3.01)) < 0.05)
    }

    @Test func halvingAmplitudeDropsSixDecibels() {
        let loud = LevelMeter.rmsDBFS(sine(amplitude: 0.5, count: 16_000))
        let quiet = LevelMeter.rmsDBFS(sine(amplitude: 0.25, count: 16_000))
        #expect(abs((loud - quiet) - 6.02) < 0.05)
    }

    @Test func silenceAndEmptyInputHitTheFloor() {
        #expect(LevelMeter.rmsDBFS([Int16](repeating: 0, count: 100)) == LevelMeter.floorDBFS)
        #expect(LevelMeter.rmsDBFS([Int16]()) == LevelMeter.floorDBFS)
        #expect(LevelMeter.isDigitalSilence([Int16](repeating: 0, count: 10)))
        #expect(!LevelMeter.isDigitalSilence([0, 0, 1]))
    }

    @Test func barScalesBetweenFloorAndZero() {
        #expect(LevelMeter.bar(dbfs: 0, width: 10) == "##########")
        #expect(LevelMeter.bar(dbfs: -35, width: 10, floor: -70) == "#####-----")
        #expect(LevelMeter.bar(dbfs: -120, width: 10) == "----------")
    }
}

func sine(amplitude: Double, count: Int, frequency: Double = 440) -> [Int16] {
    var samples: [Int16] = []
    for index in 0..<count {
        let phase = 2 * Double.pi * frequency * Double(index) / Double(AudioChunk.sampleRate)
        samples.append(Int16(amplitude * 32767 * sin(phase)))
    }
    return samples
}
