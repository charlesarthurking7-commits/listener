import AppKit
import ListenerCore
import Observation

/// Dictation into any app: fn twice starts it, fn once more stops it, and Escape throws
/// it away. The words go through on-device speech recognition from the Mac's own
/// microphone, are tidied by Claude for the app in front, and are pasted at the cursor.
/// Names and terms the user then corrects are learned for next time. Calls have the
/// microphone to themselves, so dictation is off during one.
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        case listening
        /// Settling the speech, tidying it and pasting it.
        case working
        /// A short note shown instead of typing, e.g. that nothing was heard.
        case note(String)
        /// A word just learned from a correction, which the capsule offers to undo.
        case learned(String)
    }

    /// Past this, dictation stops by itself and types what it has.
    static let maxLength: Duration = .seconds(600)
    static let noteDuration: Duration = .seconds(3)
    /// Long enough to read the word and reach Undo.
    static let learnedDuration: Duration = .seconds(6)

    private(set) var phase = Phase.idle
    /// How loud the microphone is, from 0 to 1, while listening.
    private(set) var level = 0.0
    /// The last text dictation typed, in memory only, for pasting again from the menu.
    @ObservationIgnored private var lastPaste: TextInserter.Paste?

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private let isCallRunning: () -> Bool
    @ObservationIgnored private var monitor: FnKeyMonitor?
    @ObservationIgnored private var settings: Settings
    @ObservationIgnored private var recorder: DictationRecorder?
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var lengthLimit: Task<Void, Never>?
    @ObservationIgnored private var noteTimer: Task<Void, Never>?
    /// Bumped by every start and cancel, so work for an earlier dictation stops short.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var speech: (key: String, provider: any SpeechToTextProvider)?
    /// Loaded at launch and kept, so dictation never waits for its model.
    @ObservationIgnored private let parakeet = ParakeetSpeechProvider()
    @ObservationIgnored private var model: (any LanguageModelProvider)?
    @ObservationIgnored private let watcher = CorrectionWatcher()
    /// Read again at each start, so words removed from the file by hand stay forgotten.
    @ObservationIgnored private var dictionary = LearnedDictionary()

    init(environment: AppEnvironment, isCallRunning: @escaping () -> Bool) {
        self.environment = environment
        self.isCallRunning = isCallRunning
        settings = environment.launchSettings.settings
        guard settings.dictation.enabled else {
            return
        }
        let monitor = FnKeyMonitor { [weak self] signal in
            self?.handle(signal)
        }
        monitor.onStart = { [weak self] in
            self?.onWatchingFn?()
        }
        monitor.start()
        self.monitor = monitor
        if settings.dictation.recognizer == "parakeet" {
            Task.detached(priority: .utility) { [parakeet] in
                do {
                    try await parakeet.prepare()
                } catch {
                    Log.dictation.error("Parakeet could not load: \(ErrorText.describe(error), privacy: .public)")
                }
            }
        }
    }

    /// dictation.enabled was on at launch.
    var isEnabled: Bool { monitor != nil }
    /// fn is being watched, so dictation can start from the keyboard.
    var isWatchingFn: Bool { monitor?.isRunning ?? false }
    /// Called when fn starts being watched after launch, once permission is granted.
    @ObservationIgnored var onWatchingFn: (() -> Void)?
    var isActive: Bool { phase == .listening || phase == .working }

    /// The menu's Start and Stop.
    func toggle() {
        if phase == .listening {
            stop()
        } else {
            start()
        }
    }

    func handle(_ signal: FnKeyMonitor.Signal) {
        switch signal {
        case .tap(.double) where !isActive:
            start()
        case .tap(.single) where phase == .listening:
            monitor?.actedOnSingleTap()
            stop()
        case .escape where isActive:
            cancel()
        default:
            break
        }
    }

    func start() {
        guard !isActive else {
            return
        }
        if isCallRunning() {
            show("Dictation is off during calls.")
            return
        }
        settings = (try? environment.loadSettings().settings) ?? settings
        watcher.stop()
        dictionary = loadDictionary()
        let speech: any SpeechToTextProvider
        do {
            speech = try speechProvider()
        } catch {
            show(ErrorText.describe(error))
            return
        }
        generation += 1
        let generation = generation
        noteTimer?.cancel()
        phase = .listening
        level = 0
        play("Tink")

        let recorder = DictationRecorder(
            source: LiveAudioSources.dictationMicrophone(settings: settings.dictation), speech: speech)
        self.recorder = recorder
        let pressedAt = ContinuousClock.now
        starting = Task {
            do {
                let info = try await recorder.start { [weak self] dbfs in
                    Task { @MainActor in
                        self?.hear(dbfs, generation: generation)
                    }
                }
                let readyMs = Int((ContinuousClock.now - pressedAt).inSeconds * 1000)
                Log.dictation.info(
                    "Dictating from \(info.device, privacy: .private), recognizer ready in \(readyMs) ms")
            } catch {
                guard generation == self.generation else {
                    return
                }
                // A stop pressed meanwhile has nothing to type; this says why.
                self.generation += 1
                Log.dictation.error("Dictation did not start: \(ErrorText.describe(error), privacy: .public)")
                show("Dictation could not start: \(ErrorText.describe(error))")
            }
        }
        if settings.dictation.tidy, let model = languageModel() {
            Task { await model.warmUp() }
        }
        lengthLimit = Task {
            try? await Task.sleep(for: Self.maxLength)
            if !Task.isCancelled, generation == self.generation {
                stop()
            }
        }
    }

    func stop() {
        guard phase == .listening, let recorder else {
            return
        }
        let generation = generation
        phase = .working
        level = 0
        lengthLimit?.cancel()
        play("Pop")
        let stoppedAt = ContinuousClock.now
        // Read now, where the text will be pasted, not where the cursor was at the start.
        let destination = DictationTargets.current()
        let readMs = Int((ContinuousClock.now - stoppedAt).inSeconds * 1000)
        Log.dictation.debug("Read the cursor's surroundings in \(readMs) ms")
        let (starting, settings) = (starting, settings)
        work = Task {
            await starting?.value
            let heard = await recorder.finish()
            let settledAt = ContinuousClock.now
            guard generation == self.generation else {
                return
            }
            if let problem = heard.problem {
                Log.dictation.error("Speech recognition stopped early: \(problem, privacy: .public)")
            }
            let tidier = DictationTidier(
                model: languageModel(), settings: settings.dictation, aboutMe: settings.answers.context,
                learned: dictionary.promptTerms)
            let result = await tidier.tidy(heard.text, for: destination.target)
            guard generation == self.generation else {
                return
            }
            if let problem = result.problem {
                // The next dictation reads the key again, in case it was the problem.
                model = nil
                Log.dictation.error("Typed the words as heard: \(problem, privacy: .public)")
            }
            log(
                heard: heard.text, typed: result, settling: settledAt - stoppedAt,
                total: ContinuousClock.now - stoppedAt)
            guard !result.text.isEmpty else {
                show(heard.problem == nil ? "No words were heard." : "Speech recognition failed.")
                return
            }
            let paste = TextInserter.Paste(
                result.text, formattingLists: settings.dictation.formattedLists, font: destination.font)
            lastPaste = paste
            switch TextInserter.insert(paste) {
            case .pasted:
                finish(generation)
                if settings.dictation.learnWords, let field = destination.field, let cursor = destination.cursor {
                    watcher.watch(field, at: cursor, typed: paste.text) { [weak self] corrections in
                        self?.learn(corrections)
                    }
                }
            case .copied:
                show("Copied. Allow Listener in Accessibility to have it pasted for you.")
            }
        }
    }

    /// Escape: nothing is typed.
    func cancel() {
        guard isActive else {
            return
        }
        let stage = phase == .listening ? "listening" : "tidying"
        Log.dictation.info("Dictation cancelled while \(stage, privacy: .public)")
        generation += 1
        lengthLimit?.cancel()
        work?.cancel()
        if let recorder {
            let starting = starting
            Task {
                await starting?.value
                await recorder.cancel()
            }
        }
        recorder = nil
        phase = .idle
        level = 0
    }

    var hasLastDictation: Bool { lastPaste != nil }

    /// Forgets the word the capsule just said was learned.
    func undoLearned() {
        guard case .learned(let term) = phase else {
            return
        }
        dictionary = loadDictionary()
        dictionary.forget(term)
        saveDictionary()
        noteTimer?.cancel()
        phase = .idle
    }

    /// Opens dictionary.txt, creating it if dictation has learned nothing yet.
    func openDictionary() {
        let file = environment.paths.dictionaryFile
        if !FileManager.default.fileExists(atPath: file.path) {
            saveDictionary()
        }
        NSWorkspace.shared.open(file)
    }

    private func learn(_ corrections: [CorrectionFinder.Correction]) {
        dictionary = loadDictionary()
        let new = corrections.filter { dictionary.learn($0) }
        guard let last = new.last else {
            return
        }
        saveDictionary()
        Log.dictation.info("Learned \(new.count) word(s) from a correction")
        guard !isActive else {
            return
        }
        noteTimer?.cancel()
        phase = .learned(last.term)
        noteTimer = Task {
            try? await Task.sleep(for: Self.learnedDuration)
            if !Task.isCancelled, phase == .learned(last.term) {
                phase = .idle
            }
        }
    }

    private func loadDictionary() -> LearnedDictionary {
        let text = (try? String(contentsOf: environment.paths.dictionaryFile, encoding: .utf8)) ?? ""
        return LearnedDictionary(text: text)
    }

    private func saveDictionary() {
        let file = environment.paths.dictionaryFile
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try dictionary.text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            Log.dictation.error("Could not save the dictionary: \(ErrorText.describe(error), privacy: .public)")
        }
    }

    /// Copies the last dictation again, e.g. when it went to the wrong place.
    func copyLastText() {
        if let lastPaste {
            TextInserter.put(lastPaste, on: NSPasteboard.general)
        }
    }

    private func finish(_ generation: Int) {
        guard generation == self.generation else {
            return
        }
        recorder = nil
        phase = .idle
    }

    private func hear(_ dbfs: Double, generation: Int) {
        guard generation == self.generation, phase == .listening else {
            return
        }
        // Quiet room noise sits near -60 dBFS and close speech near -20.
        level = min(max((dbfs + 55) / 40, 0), 1)
    }

    private func show(_ note: String) {
        Log.dictation.info("Dictation note: \(note, privacy: .public)")
        recorder = nil
        phase = .note(note)
        level = 0
        noteTimer?.cancel()
        noteTimer = Task {
            try? await Task.sleep(for: Self.noteDuration)
            if !Task.isCancelled, phase == .note(note) {
                phase = .idle
            }
        }
    }

    private func play(_ name: String) {
        guard settings.dictation.sounds, let sound = NSSound(named: name) else {
            return
        }
        sound.volume = 0.25
        sound.play()
    }

    /// One provider per language and recognizer, so models load once and stay loaded.
    private func speechProvider() throws -> any SpeechToTextProvider {
        let key = settings.speech.languageCode + " " + settings.dictation.recognizer
        if let speech, speech.key == key {
            return speech.provider
        }
        let provider = try DictationSpeech.provider(settings: settings, parakeet: parakeet)
        speech = (key, provider)
        return provider
    }

    private func languageModel() -> (any LanguageModelProvider)? {
        if model == nil {
            model = environment.makeLanguageModel()
        }
        return model
    }

    private func log(heard: String, typed: DictationTidier.Result, settling: Duration, total: Duration) {
        let words = DictationTidier.wordCount(heard)
        let settlingMs = Int(settling.inSeconds * 1000)
        let totalMs = Int(total.inSeconds * 1000)
        let cost = typed.usage.flatMap { usage in
            settings.prices.models[settings.dictation.model.model]?.cost(of: usage)
        }
        let dollars = String(format: "%.5f", cost ?? 0)
        Log.dictation.info(
            "Dictated \(words) words: settled \(settlingMs) ms, typed \(totalMs) ms after stop, $\(dollars, privacy: .public)"
        )
    }
}
