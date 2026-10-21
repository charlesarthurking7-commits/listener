import AVFoundation
import CoreMedia
import ListenerCore
import Speech

#if compiler(>=6.2)
    /// Starts SpeechAnalyzer sessions for `RotatingSpeechStream`.
    @available(macOS 26.0, *)
    struct AppleRecognizer: SessionRecognizer {
        let model: InstalledModel

        func startSession() async throws -> any RecognizerSession {
            do {
                return try await AppleRecognizerSession.start(model: model)
            } catch {
                throw AppleSpeechError.from(error, language: model.language)
            }
        }
    }

    /// One SpeechAnalyzer with its own SpeechTranscriber. A module must never join a second
    /// analyzer (that traps the process), so every session builds both.
    ///
    /// `send` is only called from the stream's actor, one chunk at a time, which is what
    /// makes the converter state in `audio` safe: hence @unchecked Sendable.
    @available(macOS 26.0, *)
    final class AppleRecognizerSession: RecognizerSession, @unchecked Sendable {
        let results: AsyncThrowingStream<RecognizerResult, any Error>
        private let analyzer: SpeechAnalyzer
        private let input: AsyncStream<AnalyzerInput>.Continuation
        private let audio: AnalyzerAudio

        /// SpeechAnalyzer traps ("Unexpected processing state", SpeechRecognizerWorker.swift:441)
        /// when two start at once while a model from an earlier call still lingers, as both
        /// channels' would at the start of every call after the first. So sessions start one
        /// at a time; the audio that arrives meanwhile is held by the stream.
        private static let starts = SerialGate()

        static func start(model: InstalledModel) async throws -> AppleRecognizerSession {
            try await starts.run { try await startNow(model: model) }
        }

        private static func startNow(model: InstalledModel) async throws -> AppleRecognizerSession {
            let transcriber = SpeechTranscriber.live(locale: model.locale)
            let analyzer = SpeechAnalyzer(
                modules: [transcriber],
                options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
            )
            try await analyzer.prepareToAnalyze(in: model.audioFormat)
            let (inputs, input) = AsyncStream<AnalyzerInput>.makeStream()
            let session = try AppleRecognizerSession(
                transcriber: transcriber, analyzer: analyzer, input: input, model: model)
            do {
                try await analyzer.start(inputSequence: inputs)
            } catch {
                await session.cancel()
                throw error
            }
            return session
        }

        private init(
            transcriber: SpeechTranscriber,
            analyzer: SpeechAnalyzer,
            input: AsyncStream<AnalyzerInput>.Continuation,
            model: InstalledModel
        ) throws {
            audio = try AnalyzerAudio(analyzerFormat: model.audioFormat)
            self.analyzer = analyzer
            self.input = input
            let (results, output) = AsyncThrowingStream<RecognizerResult, any Error>.makeStream()
            self.results = results
            let language = model.language
            Task {
                do {
                    for try await result in transcriber.results {
                        output.yield(RecognizerResult(result))
                    }
                    output.finish()
                } catch {
                    output.finish(throwing: AppleSpeechError.from(error, language: language))
                }
            }
        }

        func send(_ samples: [Int16]) throws {
            if let buffer = try audio.buffer(for: samples) {
                input.yield(AnalyzerInput(buffer: buffer))
            }
        }

        func finish() async {
            input.finish()
            // Throws when the session already failed or was cancelled. Its results have
            // ended either way, which is all the stream waits for.
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        func cancel() async {
            input.finish()
            await analyzer.cancelAndFinishNow()
        }
    }

    @available(macOS 26.0, *)
    extension RecognizerResult {
        init(_ result: SpeechTranscriber.Result) {
            let text = result.text
            let pieces = text.runs.map { run in
                Piece(
                    text: String(text[run.range].characters),
                    start: run.audioTimeRange?.start.seconds,
                    end: run.audioTimeRange?.end.seconds
                )
            }
            // CMTime.seconds is NaN for an invalid time; the mapper treats that as unknown.
            self.init(
                isFinal: result.isFinal,
                start: result.range.start.seconds,
                end: result.range.end.seconds,
                finalizedThrough: result.resultsFinalizationTime.seconds,
                pieces: pieces
            )
        }
    }
#endif
