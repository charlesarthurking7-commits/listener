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

        public init(
            languageCode: String,
            configuration: RotatingSpeechStream.Configuration = RotatingSpeechStream.Configuration(),
            onModelState: @escaping @Sendable (AppleSpeechModelState) -> Void = { _ in }
        ) {
            displayName = "Apple on-device (\(languageCode))"
            self.configuration = configuration
            loader = ModelLoader(languageCode: languageCode, onState: onModelState)
        }

        /// Takes the language from the speech settings and what counts as speech from the
        /// turn settings, so pauses mean the same here as in turn detection.
        public convenience init(
            settings: Settings,
            onModelState: @escaping @Sendable (AppleSpeechModelState) -> Void = { _ in }
        ) {
            let finalization = FinalizationTrigger.Configuration(
                speechThresholdDBFS: settings.turns.vadThresholdDBFS,
                minSpeechSeconds: Double(settings.turns.minSpeechMs) / 1000
            )
            self.init(
                languageCode: settings.speech.languageCode,
                configuration: RotatingSpeechStream.Configuration(finalization: finalization),
                onModelState: onModelState
            )
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
        private let onState: @Sendable (AppleSpeechModelState) -> Void
        private var loading: Task<InstalledModel, any Error>?

        init(languageCode: String, onState: @escaping @Sendable (AppleSpeechModelState) -> Void) {
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
            onState: @escaping @Sendable (AppleSpeechModelState) -> Void
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
            var format = await installedFormat(for: transcriber)
            if format == nil {
                do {
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        try await download(request, onState: onState)
                    }
                } catch {
                    throw AppleSpeechError.from(error, language: language)
                }
                format = await installedFormat(for: transcriber)
            }
            guard let format else {
                throw AppleSpeechError.modelNotInstalled(language: language)
            }
            onState(.ready(locale: language))
            return InstalledModel(locale: locale, audioFormat: format)
        }

        /// The analyzer's audio format, or nil while the model is missing. This is Apple's
        /// own readiness test; `AssetInventory.status` has been seen to report `.supported`
        /// on Macs where transcription works.
        private static func installedFormat(for transcriber: SpeechTranscriber) async -> AVAudioFormat? {
            let chunkFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(AudioChunk.sampleRate),
                channels: 1,
                interleaved: true
            )
            return await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber], considering: chunkFormat)
        }

        private static func download(
            _ request: AssetInstallationRequest,
            onState: @escaping @Sendable (AppleSpeechModelState) -> Void
        ) async throws {
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
