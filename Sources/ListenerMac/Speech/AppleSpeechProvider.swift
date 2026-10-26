import AVFoundation
import ListenerCore
import Speech

#if compiler(>=6.2)
    /// Speech-to-text on the Mac itself: free, and call audio never leaves the machine.
    @available(macOS 26.0, *)
    public final class AppleSpeechProvider: SpeechToTextProvider {
        public let displayName: String
        private let configuration: RotatingSpeechStream.Configuration
        private let loader: ModelLoader

        /// Takes the language from the speech settings and what counts as speech from the
        /// turn settings, so pauses mean the same here as in turn detection.
        public init(settings: Settings, onModelState: @escaping @Sendable (OnDeviceSpeechStatus) -> Void) {
            let languageCode = settings.speech.languageCode
            let finalization = FinalizationTrigger.Configuration(
                speechThresholdDBFS: settings.turns.vadThresholdDBFS,
                minSpeechSeconds: Double(settings.turns.minSpeechMs) / 1000
            )
            displayName = "Apple on-device (\(languageCode))"
            configuration = RotatingSpeechStream.Configuration(finalization: finalization)
            loader = ModelLoader(languageCode: languageCode, onState: onModelState)
        }

        public func openStream(for speaker: Speaker) async throws -> any SpeechStream {
            let model = try await loader.model()
            return try await RotatingSpeechStream.open(
                recognizer: AppleRecognizer(model: model), configuration: configuration)
        }
    }

    /// What every recognizer session of a provider shares once the model is installed.
    @available(macOS 26.0, *)
    struct InstalledModel: Sendable {
        let locale: Locale
        let audioFormat: AVAudioFormat

        var language: String {
            locale.identifier(.bcp47)
        }
    }

    @available(macOS 26.0, *)
    extension SpeechTranscriber {
        /// Volatile results feed the live interim; fast results bring them every second or
        /// so instead of every four; word times make audioStart and audioEnd precise.
        static func live(locale: Locale) -> SpeechTranscriber {
            SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.audioTimeRange]
            )
        }
    }

    /// Loads the model once per provider; both channels' streams wait on the same attempt.
    @available(macOS 26.0, *)
    actor ModelLoader {
        private let languageCode: String
        private let onState: @Sendable (OnDeviceSpeechStatus) -> Void
        private var loading: Task<InstalledModel, any Error>?

        init(languageCode: String, onState: @escaping @Sendable (OnDeviceSpeechStatus) -> Void) {
            self.languageCode = languageCode
            self.onState = onState
        }

        func model() async throws -> InstalledModel {
            if let loading {
                return try await loading.value
            }
            let task = Task { [languageCode, onState] in
                try await Self.load(languageCode: languageCode, onState: onState)
            }
            loading = task
            do {
                return try await task.value
            } catch {
                // Let the next stream try again: the download may have finished by then.
                if loading == task {
                    loading = nil
                }
                throw error
            }
        }

        static func load(
            languageCode: String,
            onState: @escaping @Sendable (OnDeviceSpeechStatus) -> Void
        ) async throws -> InstalledModel {
            onState(.checking)
            let requested = Locale(identifier: languageCode)
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                let alternatives = await supportedAlternatives(to: requested)
                throw AppleSpeechError.unsupportedLanguage(requested: languageCode, supported: alternatives)
            }
            let language = locale.identifier(.bcp47)

            // The system installs assets by a module's configuration, so this transcriber only
            // describes what the sessions will use. It never joins an analyzer.
            let transcriber = SpeechTranscriber.live(locale: locale)
            let wasInstalled = await installedFormat(for: transcriber) != nil
            do {
                // An app may only use a locale it has reserved, even when the model is
                // already on the Mac because another app installed it. Reserve explicitly
                // rather than rely on the installation request, which has nothing to do
                // when the model is already there.
                try await AssetInventory.reserve(locale: locale)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await download(request, reportingProgress: !wasInstalled, onState: onState)
                }
            } catch {
                throw AppleSpeechError.from(error, language: language)
            }
            guard let format = await installedFormat(for: transcriber) else {
                throw AppleSpeechError.modelNotInstalled(language: language)
            }
            onState(.ready(locale: language))
            return InstalledModel(locale: locale, audioFormat: format)
        }

        /// The analyzer's audio format, or nil while the model is missing. This is Apple's
        /// own readiness test; `AssetInventory.status` has been seen to report `.supported`
        /// on Macs where transcription works.
        private static func installedFormat(for transcriber: SpeechTranscriber) async -> AVAudioFormat? {
            await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: .chunk)
        }

        private static func download(
            _ request: AssetInstallationRequest,
            reportingProgress: Bool,
            onState: @escaping @Sendable (OnDeviceSpeechStatus) -> Void
        ) async throws {
            guard reportingProgress else {
                try await request.downloadAndInstall()
                return
            }
            onState(.downloading(fractionCompleted: 0))
            let reporter = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(250))
                    onState(.downloading(fractionCompleted: request.progress.fractionCompleted))
                }
            }
            defer { reporter.cancel() }
            try await request.downloadAndInstall()
        }

        /// Other regions of the same language, or every supported language if there are none.
        private static func supportedAlternatives(to requested: Locale) async -> [String] {
            let supported = await SpeechTranscriber.supportedLocales
            let sameLanguage = supported.filter { $0.language.languageCode == requested.language.languageCode }
            let candidates = sameLanguage.isEmpty ? supported : sameLanguage
            return candidates.map { $0.identifier(.bcp47) }.sorted()
        }
    }
#endif
