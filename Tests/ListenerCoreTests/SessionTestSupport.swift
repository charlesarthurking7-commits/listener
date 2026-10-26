import Foundation
import Synchronization

@testable import ListenerCore

/// Settings for a session test: everything saved under `directory`.
func sessionSettings(directory: URL) -> Settings {
    var settings = Settings()
    settings.storage.directory = directory.path
    // Priced as a Google session, so cost checks see a speech cost. The app resolves
    // "auto" to a real provider before a session starts.
    settings.speech.provider = "google"
    return settings
}

/// A channel of tone bursts wherever `speaker` speaks in `script`, so the voice
/// activity detector hears what the script says.
func scriptAudio(
    _ script: ConversationScript, speaker: Speaker, seconds: Double, frequency: Double = 300
) -> WAVAudio {
    let bursts = script.lines.filter { $0.speaker == speaker }.map { $0.start...$0.end }
    let samples = Synth.track(seconds: seconds, bursts: bursts, frequency: frequency, amplitude: 0.2)
    return WAVAudio(sampleRate: AudioChunk.sampleRate, channelCount: 1, samples: samples)
}

/// Replay sources for both channels of a scripted conversation.
func scriptSources(
    _ script: ConversationScript, seconds: Double, pacing: ReplaySource.Pacing
) throws -> [Speaker: ReplaySource] {
    [
        .me: try ReplaySource(audio: scriptAudio(script, speaker: .me, seconds: seconds), speaker: .me, pacing: pacing),
        .them: try ReplaySource(
            audio: scriptAudio(script, speaker: .them, seconds: seconds, frequency: 200),
            speaker: .them, pacing: pacing),
    ]
}

func waitForReplay(_ sources: [Speaker: ReplaySource]) async {
    for source in sources.values {
        await source.waitUntilFinished()
    }
}

/// Polls `condition` every 10 ms until it holds or `timeout` passes. Returns whether it held.
@discardableResult
func eventually(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

func near(_ value: Double?, _ expected: Double, within tolerance: Double = 1e-9) -> Bool {
    abs((value ?? .nan) - expected) < tolerance
}

extension AsyncSequence {
    func collect() async throws -> [Element] {
        var elements: [Element] = []
        for try await element in self {
            elements.append(element)
        }
        return elements
    }
}

/// Collects what a callback delivers, from whatever thread it calls back on.
final class Collected<Element: Sendable>: Sendable {
    private let elements = Mutex<[Element]>([])

    var all: [Element] { elements.withLock { $0 } }

    func add(_ element: Element) {
        elements.withLock { $0.append(element) }
    }
}

extension Collected where Element == AudioChunk {
    var samples: [Int16] { all.flatMap(\.samples) }
}

/// A recognizer result made of `(text, start, end)` words.
func volatileResult(_ words: (String, Double, Double)...) -> RecognizerResult {
    result(isFinal: false, words)
}

func finalResult(_ words: (String, Double, Double)...) -> RecognizerResult {
    result(isFinal: true, words)
}

private func result(isFinal: Bool, _ words: [(String, Double, Double)]) -> RecognizerResult {
    RecognizerResult(
        isFinal: isFinal,
        start: words.first?.1,
        end: words.last?.2,
        finalizedThrough: isFinal ? words.last?.2 : words.first?.1,
        pieces: words.map { RecognizerResult.Piece(text: $0.0, start: $0.1, end: $0.2) }
    )
}

/// Keeps every event a session sends, readable while the session runs.
final class EventRecorder: Sendable {
    private let events = Mutex<[SessionEvent]>([])

    var all: [SessionEvent] { events.withLock { $0 } }

    /// Starts recording; the task ends when the session finishes its events. `react`
    /// runs for each event, in order, before the next is taken.
    @discardableResult
    func record(
        _ session: CallSession, react: @escaping @Sendable (SessionEvent) async -> Void = { _ in }
    ) -> Task<Void, Never> {
        Task {
            for await event in session.events {
                events.withLock { $0.append(event) }
                await react(event)
            }
        }
    }

    var warnings: [String] {
        all.compactMap { if case .warning(let message) = $0 { message } else { nil } }
    }

    var costs: [CostSummary] {
        all.compactMap { if case .cost(let summary) = $0 { summary } else { nil } }
    }

    var lastTranscript: TranscriptSnapshot? {
        all.compactMap { if case .transcript(let snapshot) = $0 { snapshot } else { nil } }.last
    }

    func answerText(id: Int) -> String {
        all.compactMap { if case .answerText(id, let delta) = $0 { delta } else { nil } }.joined()
    }

    var finishedAnswers: [AnswerRecord] {
        all.compactMap { if case .answerFinished(let record) = $0 { record } else { nil } }
    }

    var failedAnswers: [(id: Int, message: String)] {
        all.compactMap { if case .answerFailed(let id, let message) = $0 { (id, message) } else { nil } }
    }

    var stoppedDirectories: [String?] {
        all.compactMap { if case .stopped(let directory) = $0 { directory } else { nil } }
    }
}

/// A capture source that delivers nothing, can be told to fail, and counts its calls.
final class FakeSource: AudioCaptureSource, Sendable {
    struct Failure: Error, Equatable {}

    let speaker: Speaker
    let fails: Bool
    let startDelay: Duration
    private let counts = Mutex((starts: 0, stops: 0))

    init(_ speaker: Speaker, fails: Bool = false, startDelay: Duration = .zero) {
        self.speaker = speaker
        self.fails = fails
        self.startDelay = startDelay
    }

    var starts: Int { counts.withLock { $0.starts } }
    var stops: Int { counts.withLock { $0.stops } }

    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo {
        counts.withLock { $0.starts += 1 }
        try await Task.sleep(for: startDelay)
        if fails {
            throw Failure()
        }
        return ChannelInfo(speaker: speaker, backend: "fake", device: "none", nativeFormat: "16 kHz")
    }

    func stop() {
        counts.withLock { $0.stops += 1 }
    }
}

/// A conversation with a question from Them in the middle, used by several tests.
let tradeScript = ConversationScript(
    title: "EUR fills",
    lines: [
        .init(speaker: .them, start: 0.5, end: 2.0, text: "Hi, thanks for joining the call."),
        .init(speaker: .me, start: 2.6, end: 3.6, text: "Happy to help."),
        .init(speaker: .them, start: 4.2, end: 6.0, text: "Can you confirm the EUR fills from this morning?"),
        .init(speaker: .me, start: 7.0, end: 8.5, text: "Yes, all fills settled at the quoted price."),
        .init(speaker: .them, start: 9.0, end: 10.0, text: "Great, thanks."),
    ])

let tradeAnswer = "Confirm the EUR fills settled at the quoted price, and offer the fill report."
let tradeSummary = "## Summary\n\nEUR fills confirmed.\n\n## Action items\n\n- Send the fill report."

/// Answers hotkeys with `tradeAnswer` and summaries with `tradeSummary`.
func tradeModel(
    firstTokenDelay: Duration = .milliseconds(50), tokenInterval: Duration = .milliseconds(5)
) -> ScriptedLanguageModel {
    // The deep tier uses the summary's model too; the settings as a whole differ.
    let summarySettings = SummarySettings().model
    return ScriptedLanguageModel(
        firstTokenDelay: firstTokenDelay, tokenInterval: tokenInterval,
        usage: TokenUsage(inputTokens: 1_200, outputTokens: 40)
    ) { request in
        request.settings == summarySettings ? tradeSummary : tradeAnswer
    }
}

extension ModelRequest {
    var userText: String { user.map(\.text).joined(separator: "\n") }
}

/// A capture source the test drives by hand. The first `play(until:)` stamps its audio
/// as if it had been captured in real time up to now; later audio continues that clock.
final class PushSource: AudioCaptureSource, Sendable {
    private struct State {
        var onChunk: (@Sendable (AudioChunk) -> Void)?
        var origin: ContinuousClock.Instant?
        var delivered = 0
    }

    let speaker: Speaker
    let samples: [Int16]
    private let state = Mutex(State())

    init(speaker: Speaker, samples: [Int16]) {
        self.speaker = speaker
        self.samples = samples
    }

    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo {
        state.withLock { $0.onChunk = onChunk }
        return ChannelInfo(speaker: speaker, backend: "push", device: "test", nativeFormat: "16 kHz")
    }

    func stop() {
        state.withLock { $0.onChunk = nil }
    }

    /// When the sample at `seconds` was captured, once playing has begun.
    func capturedAt(_ seconds: Double) -> ContinuousClock.Instant? {
        state.withLock { $0.origin }.map { $0 + .seconds(seconds) }
    }

    /// Delivers the audio up to `seconds` in 100 ms chunks.
    func play(until seconds: Double) {
        let rate = Double(AudioChunk.sampleRate)
        let end = min(Int((seconds * rate).rounded()), samples.count)
        state.withLock { state in
            let origin = state.origin ?? .now - .seconds(Double(end) / rate)
            state.origin = origin
            while state.delivered < end {
                let next = min(state.delivered + AudioChunk.sampleRate / 10, end)
                let chunk = AudioChunk(
                    speaker: speaker, samples: Array(samples[state.delivered..<next]),
                    capturedAt: origin + .seconds(Double(next) / rate))
                state.onChunk?(chunk)
                state.delivered = next
            }
        }
    }
}

/// A capture source that delivers through a ContinuousAudioFeed, as the Mac's do, with
/// capture times and timer ticks the test picks, counted in seconds from its start.
final class FeedSource: AudioCaptureSource, Sendable {
    let speaker: Speaker
    private let state = Mutex<(feed: ContinuousAudioFeed, origin: ContinuousClock.Instant)?>(nil)

    init(speaker: Speaker) {
        self.speaker = speaker
    }

    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo {
        // The feed's own timer would tick an hour from now; the test ticks it instead.
        let feed = ContinuousAudioFeed(speaker: speaker, tickInterval: .seconds(3600), onChunk: onChunk)
        let origin = ContinuousClock.now
        feed.start(at: origin)
        state.withLock { $0 = (feed, origin) }
        return ChannelInfo(speaker: speaker, backend: "feed", device: "test", nativeFormat: "16 kHz")
    }

    func stop() {
        state.withLock { $0?.feed }?.stop()
    }

    /// Delivers `samples` in 100 ms chunks, the last one captured at `seconds`.
    func deliver(_ samples: [Int16], endingAt seconds: Double) {
        guard let (feed, origin) = state.withLock({ $0 }) else {
            return
        }
        let end = origin + .seconds(seconds)
        var index = 0
        while index < samples.count {
            let next = min(index + AudioChunk.sampleRate / 10, samples.count)
            let capturedAt = end - SampleClock.duration(ofSamples: samples.count - next)
            feed.accept(AudioChunk(speaker: speaker, samples: Array(samples[index..<next]), capturedAt: capturedAt))
            index = next
        }
    }

    /// The feed's timer firing at `seconds`.
    func tick(at seconds: Double) {
        guard let (feed, origin) = state.withLock({ $0 }) else {
            return
        }
        feed.tick(now: origin + .seconds(seconds))
    }
}
