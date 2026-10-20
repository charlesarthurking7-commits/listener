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
///
/// A session runs once. Calling `start()` again, or `stop()` twice, does nothing more;
/// hotkeys outside a running call are ignored.
public actor CallSession {
    /// The `answerFailed` message for an answer the user cancelled or replaced.
    public static let cancelledMessage = "Cancelled"
    /// How long Stop waits for speech-to-text to deliver its last finals.
    static let finalsTimeout = Duration.seconds(3)
    /// Cost events are at most this frequent; speech cost changes every 100 ms.
    static let costInterval = Duration.milliseconds(500)

    public nonisolated let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let settings: Settings
    private let components: SessionComponents

    public init(settings: Settings, components: SessionComponents) {
        (events, continuation) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .unbounded)
        self.settings = settings
        self.components = components
        detector = TurnDetector(settings: settings.turns)
        costTracker = CostTracker(prices: settings.prices, speechProvider: settings.speech.provider)
    }

    public var isRunning: Bool { phase == .running }
    public private(set) var transcript = TranscriptSnapshot()
    /// Every answer that has ended, oldest first.
    public private(set) var answers: [AnswerRecord] = []
    /// Where this session is saved; nil before start or if the directory could not be made.
    public private(set) var directory: URL?
    public var cost: CostSummary { costTracker.summary }
    /// Session time of the speech answers are measured from right now, for tests.
    var endOfSpeech: Double? { timeline.endOfSpeech()?.end }
    /// The recent speech the voice activity detector heard, for tests.
    var speechSegments: [SpeechTimeline.Segment] { timeline.segments }

    private enum Phase {
        case idle, starting, running, stopping, stopped
    }

    private var phase = Phase.idle
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    private var origin = ContinuousClock.now
    private var startedAt = Date()
    private var endedAt: Date?
    private var channels: [ChannelInfo] = []
    private var startedSources: [any AudioCaptureSource] = []
    private var captures: [AsyncStream<AudioChunk>.Continuation] = []
    private var channelTasks: [Task<Void, Never>] = []
    private var speechChannels: [SpeechChannel] = []
    private var acceptingSpeech = true

    private var detector: TurnDetector
    private var timeline = SpeechTimeline()
    private var store: SessionStore?
    private var storageWarned = false
    private var summaryFile: String?

    private var costTracker: CostTracker
    private var lastCostEvent: ContinuousClock.Instant?
    private var costFlush: Task<Void, Never>?

    private var visible: Generation?
    private var draft: Generation?
    private var nextAnswerID = 1
    private var nextGenerationKey = 1
    /// Answers already ended whose speech had not ended or had no final yet, by speech
    /// segment id.
    private var answersAwaitingSpeech: [Int: [PendingAnswer]] = [:]

    private struct PendingAnswer {
        /// Index into `answers`.
        var index: Int
        var shownAt: Double?
    }

    /// Starts capture and recognition on every source. Throws if a source cannot
    /// start (permission denied, no device); nothing keeps running in that case.
    public func start() async throws {
        guard phase == .idle else {
            return
        }
        phase = .starting
        defer {
            for waiter in startWaiters {
                waiter.resume()
            }
            startWaiters = []
        }
        origin = .now
        startedAt = Date()
        openStore()

        var chunkStreams: [(Speaker, AsyncStream<AudioChunk>)] = []
        do {
            for speaker in Speaker.allCases {
                guard let source = components.sources[speaker] else {
                    continue
                }
                let (chunks, capture) = AsyncStream.makeStream(of: AudioChunk.self)
                captures.append(capture)
                chunkStreams.append((speaker, chunks))
                channels.append(try await source.start { capture.yield($0) })
                startedSources.append(source)
            }
        } catch {
            abandonStart()
            throw error
        }

        phase = .running
        emit(.started(channels: channels))
        for (speaker, chunks) in chunkStreams {
            let speech = SpeechChannel(speaker: speaker, provider: components.speech) { [weak self] output in
                await self?.received(output, from: speaker)
            }
            speechChannels.append(speech)
            channelTasks.append(Task { await runChannel(speaker, chunks: chunks, speech: speech) })
        }
        if let model = components.languageModel {
            Task { await model.warmUp() }
        }
        writeRecord()
    }

    private func openStore() {
        let root = SessionStore.root(for: settings.storage)
        _ = try? SessionStore.deleteExpired(in: root, retentionDays: settings.storage.retentionDays, now: startedAt)
        do {
            let store = try SessionStore(root: root, startedAt: startedAt, saveAudio: settings.storage.saveAudio)
            self.store = store
            directory = store.directory
        } catch {
            emit(.warning("This call will not be saved: \(error.localizedDescription)"))
        }
    }

    private func abandonStart() {
        for source in startedSources {
            source.stop()
        }
        for capture in captures {
            capture.finish()
        }
        startedSources = []
        captures = []
        channels = []
        if let store {
            try? store.close()
            try? FileManager.default.removeItem(at: store.directory)
        }
        store = nil
        directory = nil
        phase = .idle
    }

    /// The audio path of one channel, off the actor: framing, voice activity and
    /// silence skipping run here, and only the results hop over.
    private nonisolated func runChannel(_ speaker: Speaker, chunks: AsyncStream<AudioChunk>, speech: SpeechChannel)
        async
    {
        var processor = ChannelProcessor(turns: settings.turns, skipSilence: settings.speech.skipSilence)
        for await chunk in chunks {
            for report in processor.process(chunk) {
                await forward(report, from: speaker, to: speech)
            }
        }
        for report in processor.finish() {
            await forward(report, from: speaker, to: speech)
        }
        speech.finish()
    }

    private nonisolated func forward(_ report: FrameReport, from speaker: Speaker, to speech: SpeechChannel) async {
        // The frame's timing must reach the turn detector before any result about it can.
        await processed(report, from: speaker)
        for frame in report.toSpeech {
            speech.send(frame)
        }
    }

    private func processed(_ report: FrameReport, from speaker: Speaker) {
        guard phase == .running || phase == .stopping else {
            return
        }
        let frame = report.frame
        apply(
            detector.audioProgress(
                speaker, frame: frame.start..<frame.end, capturedAt: sessionTime(frame.chunk.capturedAt),
                activity: report.activity))
        for activity in report.activity {
            switch activity {
            case .speechStarted(let start):
                timeline.speechStarted(speaker, at: detector.sessionTime(speaker, channelTime: start))
            case .speechEnded(let end):
                if let speech = timeline.speechEnded(speaker, at: detector.sessionTime(speaker, channelTime: end)) {
                    speechChanged(speech)
                }
            }
        }
        if report.speechSeconds > 0 {
            costTracker.addSpeech(seconds: report.speechSeconds, speaker: speaker)
            costChanged()
        }
        if settings.storage.saveAudio && !frame.chunk.samples.isEmpty {
            save { try $0.appendAudio(frame.chunk.samples, for: speaker) }
        }
        if report.silenceAlarm {
            emit(.warning(silenceWarning(for: speaker)))
        }
    }

    private func received(_ output: SpeechChannel.Output, from speaker: Speaker) {
        guard acceptingSpeech, phase == .running || phase == .stopping else {
            return
        }
        switch output {
        case .warning(let message):
            emit(.warning(message))
        case .event(let event):
            if event.kind == .final && !event.text.allSatisfy(\.isWhitespace) {
                let arrived = sessionTime(.now)
                let end = event.audioEnd.map { detector.sessionTime(speaker, channelTime: $0) }
                for id in timeline.finalArrived(speaker, audioEnd: end, at: arrived) {
                    timeline.segment(id).map(speechChanged)
                }
            }
            apply(detector.speechEvent(event, speaker: speaker))
        }
    }

    private func apply(_ update: TurnDetector.Update) {
        if update.changed {
            transcript = detector.snapshot
            emit(.transcript(transcript))
            if let draft, draft.revision != detector.revision {
                cancel(draft)
                self.draft = nil
            }
        }
        for turn in update.closed {
            save { try $0.append(turn) }
            if turn.speaker == .them {
                startDraft()
            }
        }
    }

    /// A microphone never delivers exact zeros, but system audio does whenever nothing
    /// is playing, for example before the other side joins.
    private func silenceWarning(for speaker: Speaker) -> String {
        let silence = "\(speaker.rawValue) has been digital silence for \(Int(ChannelProcessor.silenceAlarmSeconds)) s"
        switch speaker {
        case .me:
            return "\(silence): check Microphone permission (System Settings > Privacy & Security > Microphone)."
        case .them:
            let name = settings.capture.systemAudioBackend == "sck" ? "Screen Recording" : "System Audio Recording"
            return "\(silence). If the call's audio is already playing, check \(name) permission "
                + "(System Settings > Privacy & Security > Screen & System Audio Recording)."
        }
    }

    /// Asks for a suggested answer from the transcript so far, including interim
    /// text. A new request cancels one still streaming. `pressedAt` is when the hotkey
    /// went down, the start of the hotkey latency clock.
    public func requestAnswer(_ tier: AnswerTier, pressedAt: ContinuousClock.Instant = .now) async {
        guard phase == .running else {
            return
        }
        guard components.languageModel != nil else {
            emit(.warning("No language model is configured, so answers are off."))
            return
        }
        let hotkey = sessionTime(pressedAt)
        finishVisible(error: Self.cancelledMessage)
        let speech = timeline.endOfSpeech()

        if tier == .quick, let drafted = draft, drafted.error == nil, drafted.revision == detector.revision,
            detector.snapshot.interim.isEmpty
        {
            draft = nil
            show(drafted, hotkey: hotkey, speech: speech)
            return
        }
        let request = PromptBuilder(answers: settings.answers)
            .answerRequest(tier: tier, transcript: detector.snapshot, now: hotkey)
        show(startGeneration(request, tier: tier, isDraft: false), hotkey: hotkey, speech: speech)
    }

    public func cancelAnswer() async {
        finishVisible(error: Self.cancelledMessage)
    }

    /// One model call: a visible answer, or a draft made ahead that may become one.
    private struct Generation {
        let key: Int
        let tier: AnswerTier
        let model: String
        let isDraft: Bool
        /// The transcript revision the request was built from.
        let revision: Int
        var task: Task<Void, Never>?
        var answerID: Int?
        var hotkeyAt: Double?
        var speech: SpeechTimeline.Segment?
        var requestSentAt: Double
        var firstTokenAt: Double?
        var doneAt: Double?
        var text = ""
        var usage: TokenUsage?
        var cost = 0.0
        var stopReason: String?
        var error: String?
    }

    private func startGeneration(_ request: ModelRequest, tier: AnswerTier, isDraft: Bool) -> Generation {
        let key = nextGenerationKey
        nextGenerationKey += 1
        var generation = Generation(
            key: key, tier: tier, model: request.settings.model, isDraft: isDraft, revision: detector.revision,
            requestSentAt: sessionTime(.now))
        guard let model = components.languageModel else {
            return generation
        }
        generation.task = Task {
            update(key) { $0.requestSentAt = sessionTime(.now) }
            do {
                for try await event in model.stream(request) {
                    modelEvent(event, key: key)
                }
                generationEnded(key, error: nil)
            } catch {
                generationEnded(key, error: error)
            }
        }
        return generation
    }

    private func show(_ generation: Generation, hotkey: Double, speech: SpeechTimeline.Segment?) {
        var generation = generation
        let id = nextAnswerID
        nextAnswerID += 1
        generation.answerID = id
        generation.hotkeyAt = hotkey
        generation.speech = speech
        visible = generation
        emit(.answerStarted(id: id, tier: generation.tier, model: generation.model))
        if !generation.text.isEmpty {
            emit(.answerText(id: id, delta: generation.text))
        }
        if generation.doneAt != nil {
            finishVisible(error: generation.error)
        }
    }

    private func modelEvent(_ event: ModelEvent, key: Int) {
        switch event {
        case .text(let delta):
            guard !delta.isEmpty else {
                return
            }
            let now = sessionTime(.now)
            let generation = update(key) {
                $0.firstTokenAt = $0.firstTokenAt ?? now
                $0.text += delta
            }
            if let id = generation?.answerID {
                emit(.answerText(id: id, delta: delta))
            }
        case .finished(let usage, let stopReason):
            guard let model = generation(key)?.model else {
                return
            }
            let cost = costTracker.addModelUsage(usage, model: model)
            costChanged()
            generationEnded(key, error: nil) {
                $0.usage = usage
                $0.cost = cost
                $0.stopReason = stopReason
            }
        }
    }

    /// The generation is done: `.finished` arrived, or the stream ended or failed.
    /// Whichever comes first counts.
    private func generationEnded(_ key: Int, error: (any Error)?, _ change: (inout Generation) -> Void = { _ in }) {
        guard generation(key)?.doneAt == nil else {
            return
        }
        let now = sessionTime(.now)
        let ended = update(key) {
            change(&$0)
            $0.doneAt = now
            $0.error = error.map { String(describing: $0) }
        }
        if let ended, ended.answerID != nil {
            finishVisible(error: ended.error)
        }
    }

    private func generation(_ key: Int) -> Generation? {
        visible?.key == key ? visible : draft?.key == key ? draft : nil
    }

    /// Changes the visible answer or the draft, whichever has this key.
    @discardableResult
    private func update(_ key: Int, _ change: (inout Generation) -> Void) -> Generation? {
        if visible?.key == key {
            change(&visible!)
            return visible
        }
        if draft?.key == key {
            change(&draft!)
            return draft
        }
        return nil
    }

    /// Ends the visible answer: records it, saves it, and tells the UI. With an error
    /// (including a cancellation) it is reported as failed.
    private func finishVisible(error: String?) {
        guard var generation = visible, let id = generation.answerID else {
            return
        }
        visible = nil
        if generation.doneAt == nil {
            cancel(generation)
            generation.doneAt = sessionTime(.now)
            generation.error = error
        }
        // A failure can come after some text (a refusal, say), which must not be kept as
        // if it were an answer. A cancelled answer keeps what the user already saw.
        let kept = generation.error == nil || generation.error == Self.cancelledMessage
        let record = AnswerRecord(
            id: id, tier: generation.tier, model: generation.model, askedAt: generation.hotkeyAt ?? 0,
            text: kept ? generation.text : "", latency: latency(of: generation), usage: generation.usage,
            cost: generation.cost, error: generation.error, fromDraft: generation.isDraft)
        answers.append(record)
        if let speech = generation.speech, speech.end == nil || speech.finalAt == nil {
            answersAwaitingSpeech[speech.id, default: []].append(
                PendingAnswer(index: answers.count - 1, shownAt: shownAt(generation)))
        }
        save { try $0.append(record) }
        if let error = generation.error {
            emit(.answerFailed(id: id, message: error))
        } else {
            emit(.answerFinished(record))
            if generation.stopReason == "max_tokens" {
                emit(.warning("Answer \(id) was cut short at the \(generation.tier.rawValue) answer's token limit."))
            }
        }
    }

    private func cancel(_ generation: Generation) {
        generation.task?.cancel()
    }

    private func latency(of generation: Generation) -> AnswerLatency {
        var latency = AnswerLatency()
        guard let hotkey = generation.hotkeyAt else {
            return latency
        }
        let shownAt = shownAt(generation)
        latency.hotkeyToRequestSent = milliseconds(generation.requestSentAt - hotkey)
        latency.hotkeyToFirstToken = shownAt.map { milliseconds($0 - hotkey) }
        latency.hotkeyToDone = generation.doneAt.map { milliseconds(max($0, hotkey) - hotkey) }
        if let speech = generation.speech {
            measure(&latency, from: speech, hotkey: hotkey, shownAt: shownAt)
        }
        return latency
    }

    /// When the user saw the first token. A draft may have produced text before the
    /// hotkey; it was shown at the hotkey.
    private func shownAt(_ generation: Generation) -> Double? {
        guard let hotkey = generation.hotkeyAt else {
            return nil
        }
        return generation.firstTokenAt.map { max($0, hotkey) }
    }

    private func measure(
        _ latency: inout AnswerLatency, from speech: SpeechTimeline.Segment, hotkey: Double, shownAt: Double?
    ) {
        guard let end = speech.end else {
            return
        }
        latency.endOfSpeechToHotkey = milliseconds(hotkey - end)
        latency.endOfSpeechToFirstToken = shownAt.map { milliseconds($0 - end) }
        latency.finalToHotkey = speech.finalAt.map { milliseconds(hotkey - $0) }
    }

    /// The speech answers are measured from ended, or its final arrived, which can be
    /// after the hotkey: the answers measured from it catch up.
    private func speechChanged(_ speech: SpeechTimeline.Segment) {
        if visible?.speech?.id == speech.id {
            visible?.speech = speech
        }
        guard let pending = answersAwaitingSpeech[speech.id] else {
            return
        }
        for answer in pending {
            var record = answers[answer.index]
            measure(&record.latency, from: speech, hotkey: record.askedAt, shownAt: answer.shownAt)
            if record != answers[answer.index] {
                answers[answer.index] = record
                save { try $0.append(record) }
            }
        }
        if speech.finalAt != nil {
            answersAwaitingSpeech[speech.id] = nil
        }
    }

    /// Drafts a quick answer when Them finishes a turn, so the hotkey can show it at once.
    private func startDraft() {
        guard settings.answers.draftAhead, phase == .running, components.languageModel != nil else {
            return
        }
        if let draft {
            cancel(draft)
        }
        let request = PromptBuilder(answers: settings.answers)
            .answerRequest(tier: .quick, transcript: detector.snapshot, now: sessionTime(.now))
        draft = startGeneration(request, tier: .quick, isDraft: true)
    }

    /// Stops capture, lets speech-to-text deliver its last finals, saves the session,
    /// writes the summary if enabled, then finishes `events`.
    public func stop() async {
        if phase == .starting {
            await withCheckedContinuation { startWaiters.append($0) }
        }
        switch phase {
        case .stopping:
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        case .stopped:
            return
        case .idle:
            phase = .stopped
            emit(.stopped(directory: nil))
            continuation.finish()
            return
        case .starting, .running:
            break
        }

        phase = .stopping
        if let draft {
            cancel(draft)
            self.draft = nil
        }
        finishVisible(error: Self.cancelledMessage)
        for source in startedSources {
            source.stop()
        }
        for capture in captures {
            capture.finish()
        }
        for task in channelTasks {
            await task.value
        }
        let speech = speechChannels
        let delivered = await finishes(within: Self.finalsTimeout) {
            for channel in speech {
                await channel.waitUntilDone()
            }
        }
        if !delivered {
            for channel in speech {
                channel.cancel()
            }
        }
        acceptingSpeech = false
        apply(detector.finish())

        costFlush?.cancel()
        costFlush = nil
        emitCost()
        endedAt = Date()
        writeRecord()
        save { try $0.close() }
        await summarise()

        phase = .stopped
        emit(.stopped(directory: store?.directory.path))
        continuation.finish()
        for waiter in stopWaiters {
            waiter.resume()
        }
        stopWaiters = []
    }

    private func summarise() async {
        guard settings.summary.enabled, let model = components.languageModel, !detector.snapshot.turns.isEmpty else {
            return
        }
        emit(.summaryStarted)
        var file: String?
        do {
            let summary = try await SessionSummarizer.generate(
                turns: detector.snapshot.turns, settings: settings, model: model, startedAt: startedAt,
                duration: endedAt?.timeIntervalSince(startedAt))
            if let usage = summary.usage {
                costTracker.addModelUsage(usage, model: summary.model)
                emitCost()
            }
            if let store {
                file = try store.writeSummary(summary.markdown).path
                summaryFile = SessionStore.summaryFile
                writeRecord()
            }
        } catch {
            emit(.warning("The summary failed: \(error)"))
        }
        emit(.summaryFinished(markdownFile: file))
    }

    private func writeRecord() {
        let record = SessionRecord(
            startedAt: startedAt, endedAt: endedAt, channels: channels,
            speechProvider: components.speech.displayName, settings: settings,
            turnCount: detector.snapshot.turns.count, answers: answers, cost: costTracker.summary,
            summaryFile: summaryFile)
        save { try $0.write(record) }
    }

    /// Runs a write against the store. The first failure is reported; the call goes on.
    private func save(_ write: (SessionStore) throws -> Void) {
        guard let store else {
            return
        }
        do {
            try write(store)
        } catch {
            if !storageWarned {
                storageWarned = true
                emit(.warning("Part of this call could not be saved: \(error.localizedDescription)"))
            }
        }
    }

    private func costChanged() {
        guard costFlush == nil else {
            return
        }
        let wait = lastCostEvent.map { $0 + Self.costInterval - .now } ?? .zero
        if wait <= .zero {
            emitCost()
            return
        }
        costFlush = Task {
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else {
                return
            }
            costFlush = nil
            emitCost()
        }
    }

    private func emitCost() {
        lastCostEvent = .now
        emit(.cost(costTracker.summary))
    }

    private func emit(_ event: SessionEvent) {
        continuation.yield(event)
    }

    private func sessionTime(_ instant: ContinuousClock.Instant) -> Double {
        let parts = (instant - origin).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Tenths of a millisecond are plenty, and keep session.json readable.
    private func milliseconds(_ seconds: Double) -> Double {
        (seconds * 10_000).rounded() / 10
    }
}

/// Waits for `operation`, but no longer than `timeout`. Returns whether it finished in
/// time; an operation that overruns keeps running, and the caller decides what to cancel.
func finishes(within timeout: Duration, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    await withCheckedContinuation { continuation in
        let outcome = FirstOutcome(continuation)
        let timer = Task {
            // Cancelled means the operation won; resolving here could beat its result.
            guard (try? await Task.sleep(for: timeout)) != nil else {
                return
            }
            await outcome.resolve(false)
        }
        Task {
            await operation()
            timer.cancel()
            await outcome.resolve(true)
        }
    }
}

private actor FirstOutcome {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
