import ArgumentParser
import Foundation
import ListenerCore
import ListenerMac

enum SystemAudioBackend: String, ExpressibleByArgument, CaseIterable {
    case tap
    case sck
}

struct SpikeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spike",
        abstract:
            "Guided test that records the mic and system audio as two separate streams and reports what it measured."
    )

    @Option(help: "System audio backend: tap (Core Audio process tap) or sck (ScreenCaptureKit).")
    var system: SystemAudioBackend = .tap

    @Option(help: "Length of each of the three phases, in seconds.")
    var phaseSeconds: Double = 10

    @Option(help: "Output directory for me.wav, them.wav, report.json and spike.log.")
    var out: String?

    @Flag(help: "Turn on Apple voice processing (echo cancellation) for the mic.")
    var voiceProcessing = false

    func run() async throws {
        let outputDirectory = try makeOutputDirectory()
        let log = try SpikeLog(url: outputDirectory.appendingPathComponent("spike.log"))
        let systemPermission = system == .tap ? "System Audio Recording" : "Screen Recording"
        log.write(
            "Listener audio spike, system audio via \(system == .tap ? "Core Audio process tap" : "ScreenCaptureKit")")
        log.write("First run: macOS asks for Microphone and \(systemPermission) access. Allow both, then run again.")

        var captureSettings = CaptureSettings()
        captureSettings.systemAudioBackend = system.rawValue
        captureSettings.voiceProcessing = voiceProcessing
        let sources = LiveAudioSources.make(settings: captureSettings) { log.write($0.description) }
        guard let microphone = sources[.me], let systemAudio = sources[.them] else {
            throw ExitCode.failure
        }
        let recorder = try SpikeRecorder(outputDirectory: outputDirectory, startedAt: .now)

        let meInfo: ChannelInfo
        let themInfo: ChannelInfo
        do {
            meInfo = try await microphone.start { recorder.record($0) }
            themInfo = try await systemAudio.start { recorder.record($0) }
        } catch {
            microphone.stop()
            systemAudio.stop()
            log.write("Could not start capture: \(error)")
            throw ExitCode.failure
        }
        log.write("Me:   \(meInfo.backend), \(meInfo.device), \(meInfo.nativeFormat)")
        log.write("Them: \(themInfo.backend), \(themInfo.device), \(themInfo.nativeFormat)")

        // Measured from here so time spent on permission prompts doesn't dilute the figure.
        let cpuWindowStart = recorder.secondsSinceStart()
        let cpuAtStart = ProcessCPU.seconds()

        // Give the user a moment to read the first instruction before it counts.
        let origin = recorder.secondsSinceStart() + 3
        let phases = SpikePhase.standard(secondsEach: phaseSeconds, startingAt: origin)
        log.write("")
        log.write("Starting in 3 seconds: \(phases[0].instruction)")

        for phase in phases {
            try await waitUntil(origin: phase.start, recorder: recorder)
            log.write("")
            log.write("== \(phase.name.uppercased()) (\(Int(phaseSeconds)) s): \(phase.instruction)")
            while recorder.secondsSinceStart() < phase.end {
                try await Task.sleep(for: .seconds(1))
                log.write(meterLine(recorder: recorder, origin: origin))
            }
        }

        let captureSeconds = recorder.secondsSinceStart()
        microphone.stop()
        systemAudio.stop()
        let cpuSeconds = ProcessCPU.seconds() - cpuAtStart
        try recorder.finish()

        let report = SpikeAnalyzer().makeReport(
            me: (recorder.trace(for: .me), meInfo),
            them: (recorder.trace(for: .them), themInfo),
            phases: phases,
            captureSeconds: captureSeconds,
            voiceProcessing: voiceProcessing,
            cpuPercentOfOneCore: cpuSeconds / (captureSeconds - cpuWindowStart) * 100,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
        try report.jsonData().write(to: outputDirectory.appendingPathComponent("report.json"))

        log.write("")
        log.write(report.renderText())
        log.write("")
        log.write("Listen to me.wav and them.wav in \(outputDirectory.path) to confirm by ear.")
        if !report.allPassed {
            throw ExitCode(2)
        }
    }

    private func makeOutputDirectory() throws -> URL {
        let directory: URL
        if let out {
            directory = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Listener/spike")
                .appendingPathComponent(formatter.string(from: Date()))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitUntil(origin: Double, recorder: SpikeRecorder) async throws {
        let remaining = origin - recorder.secondsSinceStart()
        if remaining > 0 {
            try await Task.sleep(for: .seconds(remaining))
        }
    }

    private func meterLine(recorder: SpikeRecorder, origin: Double) -> String {
        let now = recorder.secondsSinceStart()
        let me = recorder.trace(for: .me).level(since: now - 1)
        let them = recorder.trace(for: .them).level(since: now - 1)
        let elapsed = String(format: "%4.0fs", now - origin)
        let meText = "Me \(LevelMeter.bar(dbfs: me)) \(String(format: "%4.0f", me)) dBFS"
        let themText = "Them \(LevelMeter.bar(dbfs: them)) \(String(format: "%4.0f", them)) dBFS"
        return "\(elapsed)  \(meText)   \(themText)"
    }
}

/// Writes every line to stdout and to a file. When the app is launched through
/// `open`, stdout goes nowhere, so the file is what scripts/spike.sh shows. Capture
/// sources log their restarts from their own queues, hence Sendable.
final class SpikeLog: Sendable {
    private let handle: FileHandle

    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func write(_ line: String) {
        print(line)
        fflush(stdout)
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

enum ProcessCPU {
    /// User plus system CPU time used by this process so far.
    static func seconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}
