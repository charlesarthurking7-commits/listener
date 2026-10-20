import Foundation
import Synchronization
import Testing

@testable import ListenerCore

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// What the pipeline itself costs on the three fixture calls: CPU time of the audio
/// path, and answer latency and cost with stand-in providers that take as long as real
/// ones (a final 500 ms after the speech, like Google; a first token after 400 ms, like
/// Haiku). Off by default, because the calls play at real time (about 70 s). Run it with
///
///     LISTENER_BENCHMARK=1 swift test -c release -Xswiftc -enable-testing --filter PipelineBenchmark
///
/// It cannot say how fast Google or Claude really are: that takes live credentials, on
/// the Mac, with `listener replay Fixtures/<call>/me.wav Fixtures/<call>/them.wav --ask-at
/// <times>`, which prints the same latency stages.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LISTENER_BENCHMARK"] != nil))
struct PipelineBenchmark {
    static let finalDelay = 0.5
    static let firstToken = Duration.milliseconds(400)
    static let answerTokenInterval = Duration.milliseconds(15)
    static let summaryTokenInterval = Duration.milliseconds(10)
    /// How long after the question ends the hotkey goes down.
    static let reaction = 0.3

    @Test func audioPathCPUTime() throws {
        var channels: [[Int16]] = []
        for call in FixtureCall.all {
            for speaker in Speaker.allCases {
                channels.append(try call.audio(speaker).samples)
            }
        }
        let rate = Double(AudioChunk.sampleRate)
        let minutes = Double(channels.reduce(0) { $0 + $1.count }) / rate / 60
        let frames = channels.map { $0.chunks(of: AudioChunk.sampleRate / 10) }
        // Capture devices deliver whatever buffer sizes they like; the framer re-cuts them.
        let uneven = channels.map { samples in
            Synth.split(samples, sizes: [441, 1_024, 160, 2_048]).map {
                AudioChunk(speaker: .them, samples: Array($0), capturedAt: .now)
            }
        }

        func processing(_ chunks: [[AudioChunk]], skipSilence: Bool) -> Double {
            cpuSeconds {
                for channel in chunks {
                    var processor = ChannelProcessor(turns: TurnSettings(), skipSilence: skipSilence)
                    for chunk in channel {
                        _ = processor.process(chunk)
                    }
                    _ = processor.finish()
                }
            }
        }

        var rows: [(String, Double)] = [
            ("Framing and voice activity, 100 ms chunks", processing(frames, skipSilence: false) / minutes),
            ("Framing and voice activity, uneven chunks", processing(uneven, skipSilence: false) / minutes),
            ("The same with silence skipping", processing(uneven, skipSilence: true) / minutes),
        ]
        let trigger = cpuSeconds {
            for channel in frames {
                var trigger = FinalizationTrigger()
                for chunk in channel {
                    _ = trigger.process(chunk.samples)
                }
            }
        }
        rows.append(("On-device finalization trigger", trigger / minutes))

        let directory = try temporaryDirectory("benchmark")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try WAVWriter(
            url: directory.appendingPathComponent("audio.wav"), sampleRate: AudioChunk.sampleRate)
        let saving = try cpuSeconds {
            for channel in frames {
                for chunk in channel {
                    try writer.append(chunk.samples)
                }
            }
        }
        try writer.finish()
        rows.append(("Saving audio to WAV", saving / minutes))

        for inputRate in [48_000, 44_100] {
            // A minute of capture in 10 ms device buffers.
            let buffer = inputRate / 100
            let minute = (0..<inputRate * 60).map { Int16(truncatingIfNeeded: ($0 &* 7_919) % 20_000 - 10_000) }
            let buffers = stride(from: 0, to: minute.count, by: buffer).map {
                Array(minute[$0..<min($0 + buffer, minute.count)])
            }
            var resampler = try Resampler(inputRate: inputRate)
            let seconds = cpuSeconds {
                for samples in buffers {
                    _ = resampler.process(samples)
                }
            }
            rows.append(("Resampling \(String(format: "%g", Double(inputRate) / 1_000)) kHz to 16 kHz", seconds))
        }

        var report = "\nAudio path CPU time per minute of one channel's audio (\(format(minutes, 1)) min measured)\n"
        report += TextTable.render(
            headers: ["Stage", "CPU ms per min", "Share of a core"],
            rows: rows.map { [$0.0, format($0.1 * 1_000, 2), format($0.1 / 60 * 100, 4) + " %"] },
            leftAligned: [0])
        print(report)
    }

    @Test func fixtureCallsAtRealTime() async throws {
        let cpuBefore = processCPUSeconds()
        let results = try await withThrowingTaskGroup(of: CallResult.self) { group in
            for call in FixtureCall.all {
                group.addTask { try await Self.run(call) }
            }
            var results: [CallResult] = []
            for try await result in group {
                results.append(result)
            }
            return results.sorted { $0.name < $1.name }
        }
        let cpu = processCPUSeconds() - cpuBefore
        let audioMinutes = results.reduce(0) { $0 + $1.seconds } * 2 / 60

        let answers = results.flatMap(\.answers)
        for answer in answers {
            #expect(answer.error == nil)
        }
        let latencies = answers.map(\.latency)
        let firstTokenMs = milliseconds(Self.firstToken)
        var rows: [[String]] = []
        func row(_ name: String, _ values: [Double]) {
            guard let stats = LatencyStats.Percentiles(values) else {
                rows.append([name, "-", "-", "-", "0"])
                return
            }
            rows.append([
                name, format(stats.p50, 1), format(stats.p90, 1), format(values.max() ?? 0, 1), "\(stats.count)",
            ])
        }
        row("End of speech > first token", latencies.compactMap(\.endOfSpeechToFirstToken))
        row("End of speech > hotkey", latencies.compactMap(\.endOfSpeechToHotkey))
        row("Final > hotkey", latencies.compactMap(\.finalToHotkey))
        row("Hotkey > request to the model", latencies.compactMap(\.hotkeyToRequestSent))
        row("Hotkey > first token", latencies.compactMap(\.hotkeyToFirstToken))
        row("  of which the pipeline", latencies.compactMap { $0.hotkeyToFirstToken.map { $0 - firstTokenMs } })
        row("Hotkey > answer done", latencies.compactMap(\.hotkeyToDone))
        row("End of speech > final on screen", results.flatMap(\.finalOnScreen))
        row("  of which the pipeline", results.flatMap(\.finalPipeline))

        var report = "\nFixture calls at real time: Google-like final \(Int(Self.finalDelay * 1_000)) ms after "
        report += "the speech, Haiku-like first token \(Int(firstTokenMs)) ms after the request, "
        report += "hotkey \(Int(Self.reaction * 1_000)) ms after each hard question\n"
        report += TextTable.render(headers: ["Stage (ms)", "p50", "p90", "max", "n"], rows: rows, leftAligned: [0])
        report += "The final's own pipeline time starts when the 100 ms frame that completes it was captured.\n"
        report += "\nProcess CPU: \(format(cpu, 2)) s for \(format(audioMinutes, 2)) min of audio "
        report += "(\(format(cpu / audioMinutes * 1_000, 1)) ms per channel-minute), everything included.\n"

        var costRows: [[String]] = []
        for result in results {
            func cost(_ model: String) -> Double {
                result.cost.modelUsage[model].map { PriceTable.standard.models[model]?.cost(of: $0) ?? 0 } ?? 0
            }
            costRows.append([
                result.name, format(result.seconds / 60, 2), "\(result.answers.count)",
                "$" + format(result.cost.speechCost, 4), "$" + format(cost("claude-haiku-5-5"), 5),
                "$" + format(cost("claude-sonnet-5-5"), 4), "$" + format(result.cost.total, 4),
            ])
        }
        report += "\nCost with the standard price table (tokens estimated from the prompts as the app budgets them)\n"
        report += TextTable.render(
            headers: ["Call", "Minutes", "Answers", "Speech", "Answers (Haiku)", "Summary (Sonnet)", "Total"],
            rows: costRows, leftAligned: [0])
        print(report)
    }

    private struct CallResult: Sendable {
        var name: String
        var seconds: Double
        var answers: [AnswerRecord]
        /// Per line: the end of its speech to its turn first showing, in milliseconds.
        var finalOnScreen: [Double]
        /// Per line: the capture of the frame that made the recogniser send the final to
        /// its turn first showing, in milliseconds.
        var finalPipeline: [Double]
        var cost: CostSummary
    }

    private static func run(_ call: FixtureCall) async throws -> CallResult {
        let script = try call.script()
        let root = try temporaryDirectory("benchmark-\(call.name)")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = sessionSettings(directory: root)
        let summarySettings = settings.summary.model

        var sources: [Speaker: ClockedSource] = [:]
        var seconds = 0.0
        for speaker in Speaker.allCases {
            let audio = try call.audio(speaker)
            seconds = Double(audio.frameCount) / Double(audio.sampleRate)
            sources[speaker] = ClockedSource(try ReplaySource(audio: audio, speaker: speaker, pacing: .realTime))
        }
        let model = EstimatingModel(
            answers: ScriptedLanguageModel(
                answer: benchmarkAnswer, firstTokenDelay: Self.firstToken, tokenInterval: Self.answerTokenInterval),
            summaries: ScriptedLanguageModel(
                answer: benchmarkSummary, firstTokenDelay: Self.firstToken, tokenInterval: Self.summaryTokenInterval),
            summarySettings: summarySettings)
        let session = CallSession(
            settings: settings,
            components: SessionComponents(
                sources: sources, speech: ScriptedSpeechToText(script: script, finalDelay: Self.finalDelay),
                languageModel: model))

        let shown = Mutex<[Int: ContinuousClock.Instant]>([:])
        let recording = EventRecorder().record(session) { event in
            guard case .transcript(let snapshot) = event else {
                return
            }
            let now = ContinuousClock.now
            shown.withLock { shown in
                for turn in snapshot.turns where shown[turn.id] == nil {
                    shown[turn.id] = now
                }
            }
        }
        try await session.start()

        let questions = script.lines.indices.dropLast().filter { index in
            let line = script.lines[index]
            return line.speaker == .them && line.text.contains("?") && script.lines[index + 1].start - line.end >= 0.85
        }
        let them = try #require(sources[.them])
        for index in questions {
            let origin = try await them.waitForStart()
            try await Task.sleep(until: origin + .seconds(script.lines[index].end + Self.reaction), clock: .continuous)
            await session.requestAnswer(.quick)
        }
        for source in sources.values {
            await source.inner.waitUntilFinished()
        }
        try await Task.sleep(for: .seconds(1))
        await session.stop()
        await recording.value

        let turns = await session.transcript.turns
        var finalOnScreen: [Double] = []
        var finalPipeline: [Double] = []
        let firstShown = shown.withLock { $0 }
        for turn in turns {
            guard let line = script.lines.first(where: { $0.speaker == turn.speaker && $0.text == turn.text }),
                let source = sources[turn.speaker], let origin = try? await source.waitForStart(),
                let at = firstShown[turn.id]
            else {
                continue
            }
            finalOnScreen.append(milliseconds(at - (origin + .seconds(line.end))))
            // The scripted recogniser finalises on the first 100 ms frame that ends at or
            // after the delay, unless the speaker's next line starts sooner.
            let due = ((line.end + Self.finalDelay) * 10 - 1e-9).rounded(.up) / 10
            if !script.lines.contains(where: { $0.speaker == line.speaker && $0.start > line.start && $0.start < due })
            {
                finalPipeline.append(milliseconds(at - (origin + .seconds(due))))
            }
        }
        return CallResult(
            name: call.name, seconds: seconds, answers: await session.answers, finalOnScreen: finalOnScreen,
            finalPipeline: finalPipeline, cost: await session.cost)
    }
}

/// Answers with fixed text at a fixed pace, reporting usage the way the app estimates
/// tokens: three bytes of prompt or reply per token.
private struct EstimatingModel: LanguageModelProvider {
    let answers: ScriptedLanguageModel
    let summaries: ScriptedLanguageModel
    let summarySettings: ModelSettings

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        let inner = (request.settings == summarySettings ? summaries : answers).stream(request)
        let prompt = TokenEstimate.tokens(in: request.system + request.user.map(\.text).joined())
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ModelEvent.self)
        let task = Task {
            var reply = ""
            do {
                for try await event in inner {
                    switch event {
                    case .text(let text):
                        reply += text
                        continuation.yield(event)
                    case .finished(_, let stopReason):
                        let usage = TokenUsage(inputTokens: prompt, outputTokens: TokenEstimate.tokens(in: reply))
                        continuation.yield(.finished(usage, stopReason: stopReason))
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func warmUp() async {}
}

/// A replay source that reports when its audio began, so a test can act at a point in
/// the recording.
private final class ClockedSource: AudioCaptureSource, Sendable {
    let inner: ReplaySource
    private let origin = Mutex<ContinuousClock.Instant?>(nil)

    init(_ inner: ReplaySource) {
        self.inner = inner
    }

    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo {
        try await inner.start { [self] chunk in
            origin.withLock { $0 = $0 ?? chunk.capturedAt - chunk.duration }
            onChunk(chunk)
        }
    }

    func stop() {
        inner.stop()
    }

    func waitForStart() async throws -> ContinuousClock.Instant {
        while true {
            if let origin = origin.withLock({ $0 }) {
                return origin
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private let benchmarkAnswer = """
    I don't have the account list in front of me, so I won't guess at numbers. I'll pull the affected \
    accounts and the slippage on each fill from the execution logs and send them over this afternoon, in \
    time for compliance. [check the incident ticket first]
    """

private let benchmarkSummary: String = {
    let bullet =
        "- The broker raised a problem with copy trading, and Me explained the cause and the next steps to take.\n"
    let item = "- [ ] **Me**: send the follow-up with the figures and the incident reference to the broker today.\n"
    return "# Call notes\n\n## Summary\n" + String(repeating: bullet, count: 8) + "\n## Decisions\nNone recorded.\n\n"
        + "## Action items\n" + String(repeating: item, count: 6) + "\n## Open questions\n"
        + String(repeating: bullet, count: 4) + "\n## Follow-up email\n" + String(repeating: bullet, count: 6)
}()

private func cpuSeconds(_ work: () throws -> Void) rethrows -> Double {
    let start = cpuClock(CLOCK_THREAD_CPUTIME_ID)
    try work()
    return cpuClock(CLOCK_THREAD_CPUTIME_ID) - start
}

private func processCPUSeconds() -> Double {
    cpuClock(CLOCK_PROCESS_CPUTIME_ID)
}

private func cpuClock(_ clock: clockid_t) -> Double {
    var time = timespec()
    clock_gettime(clock, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
}

private func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
}

private func format(_ value: Double, _ decimals: Int) -> String {
    String(format: "%.\(decimals)f", value)
}
