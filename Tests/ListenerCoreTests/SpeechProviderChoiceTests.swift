import Foundation
import Testing

@testable import ListenerCore

struct SpeechProviderChoiceTests {
    @Test func autoPrefersOnDeviceWhenAvailable() {
        #expect(SpeechProviderChoice.resolve("auto", onDeviceAvailable: true) == "apple")
        #expect(SpeechProviderChoice.resolve("auto", onDeviceAvailable: false) == "google")
    }

    @Test func explicitChoicesAreLeftAlone() {
        for provider in ["google", "apple", "fake"] {
            #expect(SpeechProviderChoice.resolve(provider, onDeviceAvailable: true) == provider)
            #expect(SpeechProviderChoice.resolve(provider, onDeviceAvailable: false) == provider)
        }
    }

    @Test func defaultSettingsResolveToARealProvider() {
        let loaded = LoadedSettings(settings: Settings())
        #expect(Settings().speech.provider == "auto")
        #expect(loaded.resolvingSpeechProvider(onDeviceAvailable: true).settings.speech.provider == "apple")
        #expect(loaded.resolvingSpeechProvider(onDeviceAvailable: false).settings.speech.provider == "google")
    }
}
