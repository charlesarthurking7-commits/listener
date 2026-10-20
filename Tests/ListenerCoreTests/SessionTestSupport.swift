import Foundation
import Synchronization

@testable import ListenerCore

/// Settings for a session test: everything saved under `directory`.
func sessionSettings(directory: URL) -> Settings {
    var settings = Settings()
    settings.storage.directory = directory.path
    return settings
}

/// A channel of tone bursts wherever `speaker` speaks in `script`, so the voice
/// activity detector hears what the script says.
func scriptAudio(
    _ script: ConversationScript, speaker: Speaker, seconds: Double, rate: Int = 16_000, frequency: Double = 300
) -> WAVAudio {
    let bursts = script.lines.filter { $0.speaker == speaker }.map { $0.start...$0.end }
    let samples = Synth.track(seconds: seconds, bursts: bursts, frequency: frequency, amplitude: 0.2, rate: rate)
    return WAVAudio(sampleRate: rate, channelCount: 1, samples: samples)
}

/// Replay sources for both channels of a scripted conversation: Me at 16 kHz, Them at
/// 24 kHz so the resampler is on the path too.
func scriptSources(
    _ script: ConversationScript, seconds: Double, pacing: ReplaySource.Pacing
) throws -> [Speaker: ReplaySource] {
    [
        .me: try ReplaySource(audio: scriptAudio(script, speaker: .me, seconds: seconds), speaker: .me, pacing: pacing),
        .them: try ReplaySource(
            audio: scriptAudio(script, speaker: .them, seconds: seconds, rate: 24_000, frequency: 200),
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
        all.compactMap { event in
            if case .warning(let message) = event { return message }
            return nil
        }
    }

    var costs: [CostSummary] {
        all.compactMap { event in
            if case .cost(let summary) = event { return summary }
            return nil
        }
    }

    var lastTranscript: TranscriptSnapshot? {
        all.last { event in
            if case .transcript = event { return true }
            return false
        }
        .flatMap { event in
            if case .transcript(let snapshot) = event { return snapshot }
            return nil
        }
    }

    func answerText(id: Int) -> String {
        all.compactMap { event in
            if case .answerText(id, let delta) = event { return delta }
            return nil
        }
        .joined()
    }

    var finishedAnswers: [AnswerRecord] {
        all.compactMap { event in
            if case .answerFinished(let record) = event { return record }
            return nil
        }
    }

    var failedAnswers: [(id: Int, message: String)] {
        all.compactMap { event in
            if case .answerFailed(let id, let message) = event { return (id, message) }
            return nil
        }
    }

    var stoppedDirectories: [String?] {
        all.compactMap { event in
            if case .stopped(let directory) = event { return directory }
            return nil
        }
    }
}

/// A capture source that delivers nothing, can be told to fail, and counts its calls.
final class FakeSource: AudioCaptureSource, Sendable {
    struct Failure: Error, Equatable {}

    let speaker: Speaker
    let fails: Bool
    private let counts = Mutex((starts: 0, stops: 0))

    init(_ speaker: Speaker, fails: Bool = false) {
        self.speaker = speaker
        self.fails = fails
    }

    var starts: Int { counts.withLock { $0.starts } }
    var stops: Int { counts.withLock { $0.stops } }

    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo {
        counts.withLock { $0.starts += 1 }
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
    let summaryModel = SummarySettings().model.model
    return ScriptedLanguageModel(
        firstTokenDelay: firstTokenDelay, tokenInterval: tokenInterval,
        usage: TokenUsage(inputTokens: 1_200, outputTokens: 40)
    ) { request in
        request.settings.model == summaryModel ? tradeSummary : tradeAnswer
    }
}

extension ModelRequest {
    var userText: String { user.map(\.text).joined(separator: "\n") }
}
