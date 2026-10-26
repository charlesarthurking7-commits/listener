import Testing

@testable import ListenerCore

struct FinalizationTriggerTests {
    @Test func firesOnceThePauseAfterSpeechIsLongEnough() {
        var trigger = FinalizationTrigger()
        let duringSpeech = trigger.process(Synth.tone(seconds: 1.0))
        let shortPause = trigger.process(Synth.silence(seconds: 0.3))
        let fullPause = trigger.process(Synth.silence(seconds: 0.1))
        #expect(!duringSpeech)
        #expect(!shortPause)
        #expect(fullPause)
    }

    @Test func firesOnlyOncePerStretchOfSpeech() {
        var trigger = FinalizationTrigger()
        _ = trigger.process(Synth.tone(seconds: 0.5))
        let first = trigger.process(Synth.silence(seconds: 0.5))
        let longSilence = trigger.process(Synth.silence(seconds: 5))
        _ = trigger.process(Synth.tone(seconds: 0.5))
        let second = trigger.process(Synth.silence(seconds: 0.5))
        #expect(first)
        #expect(!longSilence)
        #expect(second)
    }

    @Test func aShortGapInsideSpeechDoesNotFire() {
        var trigger = FinalizationTrigger()
        let withGap = trigger.process(Synth.tone(seconds: 0.6) + Synth.silence(seconds: 0.3) + Synth.tone(seconds: 0.6))
        let afterwards = trigger.process(Synth.silence(seconds: 0.4))
        #expect(!withGap)
        #expect(afterwards)
    }

    @Test func clicksAreNotSpeech() {
        var trigger = FinalizationTrigger()
        let first = trigger.process(Synth.tone(seconds: 0.06) + Synth.silence(seconds: 1))
        let second = trigger.process(Synth.tone(seconds: 0.06) + Synth.silence(seconds: 1))
        #expect(!first)
        #expect(!second)
    }

    @Test func silenceAloneNeverFires() {
        var trigger = FinalizationTrigger()
        let silent = trigger.process(Synth.silence(seconds: 10))
        let empty = trigger.process([])
        #expect(!silent)
        #expect(!empty)
    }

    @Test func speechTheRecognizerAlreadySettledNeedsNothing() {
        var trigger = FinalizationTrigger()
        _ = trigger.process(Synth.tone(seconds: 1.0))
        trigger.recognizerSettled(through: 0.95)
        let fired = trigger.process(Synth.silence(seconds: 1))
        #expect(!fired)
    }

    @Test func settlingEarlierSpeechDoesNotCoverNewSpeech() {
        var trigger = FinalizationTrigger()
        _ = trigger.process(Synth.silence(seconds: 1) + Synth.tone(seconds: 1))
        trigger.recognizerSettled(through: 1.2)
        let fired = trigger.process(Synth.silence(seconds: 0.5))
        #expect(fired)
    }

    @Test func chunkSizesThatDoNotFitTheWindowStillAddUp() {
        var trigger = FinalizationTrigger()
        let samples = Synth.tone(seconds: 0.5) + Synth.silence(seconds: 0.45)
        var fired = false
        for start in stride(from: 0, to: samples.count, by: 999) {
            let chunk = Array(samples[start..<min(start + 999, samples.count)])
            fired = trigger.process(chunk) || fired
        }
        #expect(fired)
    }

    @Test func quietSpeechBelowTheThresholdIsIgnored() {
        var trigger = FinalizationTrigger(configuration: .init(speechThresholdDBFS: -20))
        let fired = trigger.process(Synth.tone(seconds: 1, amplitude: 0.01) + Synth.silence(seconds: 1))
        #expect(!fired)
    }

    @Test func thePauseIsConfigurable() {
        var trigger = FinalizationTrigger(configuration: .init(pauseSeconds: 0.2))
        _ = trigger.process(Synth.tone(seconds: 0.5))
        let fired = trigger.process(Synth.silence(seconds: 0.2))
        #expect(fired)
    }
}
