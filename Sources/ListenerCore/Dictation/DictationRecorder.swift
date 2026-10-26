/// One dictation from start to stop: audio from a source into a speech stream, and the
/// stream's finals joined into what was heard.
///
/// Capture starts first and its audio is held until the recognizer is ready, so the
/// first word is not lost while the model loads.
public actor DictationRecorder {
    public struct Heard: Sendable, Equatable {
        public var text: String
        /// Why recognition stopped early, if it did. `text` holds what it heard until then.
        public var problem: String?
    }

    private let source: any AudioCaptureSource
    private let speech: any SpeechToTextProvider
    private var stream: (any SpeechStream)?
    private var audio: AsyncStream<AudioChunk>.Continuation?
    private var sending: Task<Void, any Error>?
    private var receiving: Task<Void, Never>?
    private var finals: [String] = []
    private var problem: String?

    public init(source: any AudioCaptureSource, speech: any SpeechToTextProvider) {
        self.source = source
        self.speech = speech
    }

    /// Starts capturing and recognizing. `onLevel` gets each chunk's level in dBFS, from
    /// the source's thread.
    public func start(onLevel: @escaping @Sendable (Double) -> Void) async throws -> ChannelInfo {
        let (chunks, audio) = AsyncStream<AudioChunk>.makeStream()
        self.audio = audio
        let info = try await source.start { chunk in
            onLevel(LevelMeter.rmsDBFS(chunk.samples))
            audio.yield(chunk)
        }
        let stream: any SpeechStream
        do {
            stream = try await speech.openStream(for: .me)
        } catch {
            source.stop()
            audio.finish()
            throw error
        }
        self.stream = stream
        receiving = Task { await self.receive(stream.events) }
        sending = Task {
            for await chunk in chunks {
                try await stream.send(chunk)
            }
        }
        return info
    }

    /// Stops capturing and waits for the recognizer to settle what it has heard.
    public func finish() async -> Heard {
        source.stop()
        audio?.finish()
        do {
            try await sending?.value
        } catch {
            note(error)
        }
        await stream?.finish()
        await receiving?.value
        return Heard(text: finals.joined(separator: " "), problem: problem)
    }

    /// Stops at once and throws away what was heard.
    public func cancel() {
        source.stop()
        audio?.finish()
        sending?.cancel()
        if let stream {
            Task { await stream.finish() }
        }
    }

    private func receive(_ events: AsyncThrowingStream<SpeechEvent, any Error>) async {
        do {
            for try await event in events where event.kind == .final {
                finals.append(event.text)
            }
        } catch {
            note(error)
        }
    }

    private func note(_ error: any Error) {
        if problem == nil {
            problem = ErrorText.describe(error)
        }
    }
}
