import Testing

@testable import ListenerCore

struct SpeechProviderChoiceTests {
    private func resolved(_ provider: String, onDeviceAvailable: Bool) -> String {
        var settings = Settings()
        settings.speech.provider = provider
        return LoadedSettings(settings: settings).resolvingSpeechProvider(onDeviceAvailable: onDeviceAvailable)
            .settings.speech.provider
    }

    @Test func autoPrefersOnDeviceWhenAvailable() {
        #expect(Settings().speech.provider == "auto")
        #expect(resolved("auto", onDeviceAvailable: true) == "apple")
        #expect(resolved("auto", onDeviceAvailable: false) == "google")
    }

    @Test func explicitChoicesAreLeftAlone() {
        for provider in ["google", "apple", "fake"] {
            #expect(resolved(provider, onDeviceAvailable: true) == provider)
            #expect(resolved(provider, onDeviceAvailable: false) == provider)
        }
    }
}
