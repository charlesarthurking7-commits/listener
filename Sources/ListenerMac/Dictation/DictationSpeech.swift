import ListenerCore

/// The recognizer dictation.recognizer asks for, shared by the app and `listener dictate`.
public enum DictationSpeech {
    /// Parakeet is English only here; Apple covers it while its model is not ready.
    public static func provider(
        settings: Settings, parakeet: ParakeetSpeechProvider? = nil
    ) throws -> any SpeechToTextProvider {
        let apple = try AppleSpeech.makeDictationProvider(settings: settings)
        guard settings.dictation.recognizer == "parakeet", settings.speech.languageCode.hasPrefix("en") else {
            return apple
        }
        return FallbackSpeechToText(primary: parakeet ?? ParakeetSpeechProvider(), fallback: apple) { error in
            Log.dictation.notice("Dictating with Apple's recognizer: \(ErrorText.describe(error), privacy: .public)")
        }
    }
}
