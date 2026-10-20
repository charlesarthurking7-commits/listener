import Foundation

/// What a session is built from. The app passes live capture and real providers;
/// replay and tests pass WAV sources and fakes.
public struct SessionComponents: Sendable {
    public var sources: [Speaker: any AudioCaptureSource]
    public var speech: any SpeechToTextProvider
    /// Nil disables answers and the summary, e.g. when no API key is configured.
    public var languageModel: (any LanguageModelProvider)?

    public init(
        sources: [Speaker: any AudioCaptureSource],
        speech: any SpeechToTextProvider,
        languageModel: (any LanguageModelProvider)?
    ) {
        self.sources = sources
        self.speech = speech
        self.languageModel = languageModel
    }
}

/// One call, from Start to Stop: captures both channels, streams them to
/// speech-to-text, keeps the transcript, answers on request, tracks latency and cost,
/// saves everything, and writes the summary at the end.
///
/// The UI talks to it through four calls and one event stream:
/// - `start()` when the user presses Start (capture never starts on its own),
/// - `requestAnswer(_:)` on a hotkey, `cancelAnswer()` on Escape,
/// - `stop()` when the user presses Stop,
/// - `events` delivers everything to render, in order.
public actor CallSession {
    public nonisolated let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let settings: Settings
    private let components: SessionComponents

    public init(settings: Settings, components: SessionComponents) {
        (events, continuation) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .unbounded)
        self.settings = settings
        self.components = components
    }

    public private(set) var isRunning = false
    public private(set) var transcript = TranscriptSnapshot()

    /// Starts capture and recognition on every source. Throws if a source cannot
    /// start (permission denied, no device); nothing keeps running in that case.
    public func start() async throws {
        throw CallSessionError.notImplemented
    }

    /// Asks for a suggested answer from the transcript so far, including interim
    /// text. A new request cancels one still streaming.
    public func requestAnswer(_ tier: AnswerTier) async {
        continuation.yield(.warning("Answers are not implemented yet"))
    }

    public func cancelAnswer() async {}

    /// Stops capture, lets speech-to-text deliver its last finals, saves the session,
    /// writes the summary if enabled, then finishes `events`.
    public func stop() async {
        continuation.finish()
    }
}

public enum CallSessionError: Error {
    case notImplemented
}
