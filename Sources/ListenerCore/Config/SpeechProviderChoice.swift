/// The "auto" speech provider: on-device recognition where the Mac supports it, because
/// it is free and has no network round trip, and Google Cloud everywhere else.
public enum SpeechProviderChoice {
    public static let automatic = "auto"

    public static func resolve(_ provider: String, onDeviceAvailable: Bool) -> String {
        guard provider == automatic else {
            return provider
        }
        return onDeviceAvailable ? "apple" : "google"
    }
}

extension LoadedSettings {
    /// The same settings with "auto" replaced by the provider it stands for on this Mac,
    /// so everything downstream (setup checks, pricing, session) sees a real provider.
    public func resolvingSpeechProvider(onDeviceAvailable: Bool) -> LoadedSettings {
        var resolved = self
        resolved.settings.speech.provider = SpeechProviderChoice.resolve(
            settings.speech.provider, onDeviceAvailable: onDeviceAvailable)
        return resolved
    }
}
