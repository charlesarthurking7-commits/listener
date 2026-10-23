import ArgumentParser
import Foundation
import ListenerCore

@main
struct SpeechBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speech-bench",
        abstract: "Compare speech-to-text engines on one side of a recorded call.",
        discussion: """
            Cuts the recording into the segments a live call would produce (Listener's \
            voice detector and pause length), transcribes every segment with each engine \
            and reports words caught, repeated words, how long each segment took and, \
            with --reference, the word error rate. Everything runs on this Mac.

            Engines:
            \(Engines.help)
            """
    )

    @Argument(help: "A 16 kHz mono WAV, such as them.wav from a saved call.")
    var audio: String

    @Option(help: "Comma-separated engines to run.")
    var engines = Engines.defaults.joined(separator: ",")

    @Option(help: "What was actually said in the stretch being tested, as plain text.")
    var reference: String?

    @Option(help: "Seconds into the recording to start at.")
    var start: Double = 0

    @Option(help: "Seconds of the recording to test. Leave out for the rest of it.")
    var duration: Double?

    @Option(name: .customLong("max-segment"), help: "Longest segment, in seconds.")
    var maxSegment: Double = 30

    @Option(help: "Folder for the report. Defaults to speech-bench next to the recording.")
    var output: String?

    func run() async throws {
        let url = URL(fileURLWithPath: (audio as NSString).expandingTildeInPath)
        let wav = try WAVReader.read(url: url)
        guard wav.sampleRate == AudioChunk.sampleRate, wav.channelCount == 1 else {
            throw BenchError(
                """
                \(audio) is \(wav.sampleRate) Hz with \(wav.channelCount) channels; it needs 16 kHz mono. Convert it with:
                  afconvert -f WAVE -d LEI16@16000 -c 1 "\(audio)" converted.wav
                """)
        }
        let rate = Double(AudioChunk.sampleRate)
        let first = min(Int(start * rate), wav.samples.count)
        let last = duration.map { min(first + Int($0 * rate), wav.samples.count) } ?? wav.samples.count
        let samples = Array(wav.samples[first..<last])
        let referenceText = try reference.map {
            try String(contentsOfFile: ($0 as NSString).expandingTildeInPath, encoding: .utf8)
        }

        let turns = (try? SettingsLoader().load().settings.turns) ?? TurnSettings()
        let segmenter = SpeechSegmenter(settings: turns, maxLength: maxSegment)
        let segmentation = segmenter.split(samples)
        print(Report.describe(segmentation, offset: start, threshold: turns.vadThresholdDBFS))
        guard !segmentation.segments.isEmpty else {
            throw BenchError("No speech found to transcribe.")
        }

        var runs: [EngineRun] = []
        for name in engines.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let engine = try Engines.make(name)
            runs.append(await Self.run(engine, on: samples, segmentation: segmentation, offset: start))
        }

        let report = Report(
            segmentation: segmentation, offset: start, threshold: turns.vadThresholdDBFS, runs: runs,
            reference: referenceText)
        print("\n" + report.summary())
        let folder =
            output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? url.deletingLastPathComponent().appendingPathComponent("speech-bench", isDirectory: true)
        try report.write(to: folder)
        print("\nSide-by-side transcripts: \(folder.appendingPathComponent("report.html").path)")
    }

    private static func run(
        _ engine: any SpeechEngine, on samples: [Int16], segmentation: SpeechSegmentation, offset: Double
    ) async -> EngineRun {
        var run = EngineRun(engine: engine.name)
        print("\n\(engine.name): loading (the first run downloads the model)…")
        do {
            let clock = ContinuousClock()
            run.loadSeconds = try await clock.measure { try await engine.prepare() }.seconds
            // The first call compiles and warms the model; keep it out of the timings.
            _ = try await engine.transcribe(floats(samples, segmentation.segments[0]))
            for (index, span) in segmentation.segments.enumerated() {
                let audio = floats(samples, span)
                let started = clock.now
                let text = try await engine.transcribe(audio)
                run.segments.append(SegmentResult(text: text, seconds: started.duration(to: clock.now).seconds))
                if showsProgress {
                    print("\r\(engine.name): \(index + 1) of \(segmentation.segments.count) segments", terminator: "")
                    fflush(stdout)
                }
            }
            print(showsProgress ? "" : "\(engine.name): \(segmentation.segments.count) segments done")
        } catch {
            run.error = "\(error)"
            print("\n\(engine.name) failed: \(error)")
        }
        return run
    }

    /// A progress line that rewrites itself only makes sense in a terminal.
    private static let showsProgress = isatty(STDOUT_FILENO) != 0

    private static func floats(_ samples: [Int16], _ span: AudioSpan) -> [Float] {
        let rate = Double(AudioChunk.sampleRate)
        let lower = max(0, Int(span.start * rate))
        let upper = min(samples.count, Int(span.end * rate))
        return samples[lower..<upper].map { Float($0) / 32768 }
    }
}

extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
