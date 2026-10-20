import Testing

@testable import ListenerCore

struct FinalizationTriggerTests {
    @Test func firesOnceThePauseAfterSpeechIsLongEnough() {
        var trigger = FinalizationTrigger()
        let duringSpeech = trigger.process(speech(seconds: 1.0))
        let shortPause = trigger.process(silence(seconds: 0.3))
        let fullPause = trigger.process(silence(seconds: 0.1))
        #expect(!duringSpeech)
        #expect(!shortPause)
        #expect(fullPause)
    }

    @Test func firesOnlyOncePerStretchOfSpeech() {
        var trigger = FinalizationTrigger()
        _ = trigger.process(speech(seconds: 0.5))
        let first = trigger.process(silence(seconds: 0.5))
        let longSilence = trigger.process(silence(seconds: 5))
        _ = trigger.process(speech(seconds: 0.5))
        let second = trigger.process(silence(seconds: 0.5))
        #expect(first)
        #expect(!longSilence)
        #expect(second)
    }

    @Test func aShortGapInsideSpeechDoesNotFire() {
        var trigger = FinalizationTrigger()
        let withGap = trigger.process(speech(seconds: 0.6) + silence(seconds: 0.3) + speech(seconds: 0.6))
        let afterwards = trigger.process(silence(seconds: 0.4))
        #expect(!withGap)
        #expect(afterwards)
    }

    @Test func clicksAreNotSpeech() {
        var trigger = FinalizationTrigger()
        let first = trigger.process(speech(seconds: 0.06) + silence(seconds: 1))
        let second = trigger.process(speech(seconds: 0.06) + silence(seconds: 1))
        #expect(!first)
        #expect(!second)
    }

    @Test func silenceAloneNeverFires() {
        var trigger = FinalizationTrigger()
        let silent = trigger.process(silence(seconds: 10))
        let empty = trigger.process([])
        #expect(!silent)
        #expect(!empty)
    }

    @Test func speechTheRecognizerAlreadySettledNeedsNothing() {
        var trigger = FinalizationTrigger()
        _ = trigger.process(speech(seconds: 1.0))
        trigger.recognizerSettled(through: 0.95)
        let fired = trigger.process(silence(seconds: 1))
        #expect(!fired)
    }

    @Test func settlingEarlierSpeechDoesNotCoverNewSpeech() {
        var trigger = FinalizationTrigger()
        _ = trigger.process(silence(seconds: 1) + speech(seconds: 1))
        trigger.recognizerSettled(through: 1.2)
        let fired = trigger.process(silence(seconds: 0.5))
        #expect(fired)
    }

    @Test func chunkSizesThatDoNotFitTheWindowStillAddUp() {
        var trigger = FinalizationTrigger()
        let samples = speech(seconds: 0.5) + silence(seconds: 0.45)
        var fired = false
        for start in stride(from: 0, to: samples.count, by: 999) {
            let chunk = Array(samples[start..<min(start + 999, samples.count)])
            fired = trigger.process(chunk) || fired
        }
        #expect(fired)
    }

    @Test func quietSpeechBelowTheThresholdIsIgnored() {
        var trigger = FinalizationTrigger(configuration: .init(speechThresholdDBFS: -20))
        let fired = trigger.process(sine(amplitude: 0.01, count: AudioChunk.sampleRate) + silence(seconds: 1))
        #expect(!fired)
    }

    @Test func thePauseIsConfigurable() {
        var trigger = FinalizationTrigger(configuration: .init(pauseSeconds: 0.2))
        _ = trigger.process(speech(seconds: 0.5))
        let fired = trigger.process(silence(seconds: 0.2))
        #expect(fired)
    }
}

private func speech(seconds: Double) -> [Int16] {
    sine(amplitude: 0.3, count: Int(seconds * Double(AudioChunk.sampleRate)))
}

private func silence(seconds: Double) -> [Int16] {
    [Int16](repeating: 0, count: Int(seconds * Double(AudioChunk.sampleRate)))
}
