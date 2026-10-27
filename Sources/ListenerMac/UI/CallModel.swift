import AppKit
import ListenerCore
import Observation
import os

/// The window's model: owns the running CallSession and reduces its events into a
/// CallViewState (ListenerCore), which holds all the logic. This class connects it to
/// the session, the settings and AppKit, and publishes it to the views in slices.
///
/// Each slice is assigned only when it changes, and session events are drawn at most
/// once per display frame, so a word of interim text redraws the live line and not the
/// hour of transcript above it, and a streaming answer redraws the answer alone.
@MainActor
@Observable
final class CallModel {
    private(set) var phase = CallViewState.Phase.idle
    private(set) var listeningSince: Date?
    private(set) var settledRows: [TranscriptRow] = []
    private(set) var liveRows: [TranscriptRow] = []
    /// Changes whenever either list of rows does, for following the newest line.
    private(set) var transcriptRevision = 0
    private(set) var answer: AnswerCard?
    /// The answer on screen, for layout that must not redraw with every word.
    private(set) var answerID: Int?
    private(set) var answerBlocks: [AnswerBlock] = []
    private(set) var callNotices: [Notice] = []
    private(set) var cost = CostSummary()
    private(set) var lastLatencyMs: Double?
    private(set) var outcome: CallOutcome?
    /// Counts the times summaries left unfinished last time were dealt with, written or
    /// given up on, so the calls list reads them again.
    private(set) var dueSummariesFinished = 0
    /// Which channels hear speech right now; nil while the session does not report it.
    private(set) var hearing: Set<Speaker>?

    private(set) var readiness: [ReadinessItem] = []
    /// Banners about the app rather than the call, e.g. a hotkey that is taken.
    private(set) var appNotices = NoticeList()
    /// Hotkeys that registered, for the footer and the menu.
    private(set) var activeHotkeys: [HotkeyAction: Hotkey] = [:]
    private(set) var settings: Settings
    /// The on-device model's state when speech.provider is "apple".
    private(set) var onDeviceSpeech: OnDeviceSpeechStatus?

    /// The kinds of call to pick from before Start, the one picked, and its files.
    private(set) var callTypes: [String] = []
    private(set) var callType = CallTypeLibrary.defaultType
    private(set) var callFiles: [LoadedCallType.File] = []
    /// While a pasted link is being read.
    private(set) var isImportingPage = false
    /// The call type and documents the running call started with.
    private(set) var activeCall: CallContext?

    /// How the window looks during a call; kept between launches.
    private(set) var transparency = WindowTransparency.stored
    private(set) var showsTranscriptInCall = UserDefaults.standard.bool(forKey: CallModel.transcriptKey)
    private(set) var hidesFromScreenSharing =
        UserDefaults.standard.object(forKey: CallModel.screenSharingKey) as? Bool ?? true
    private(set) var isPointerOver = false

    /// Everything about the current call. Not observed: views read the slices above, and
    /// the menu reads this when it opens.
    @ObservationIgnored private(set) var state = CallViewState()

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var session: CallSession?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    /// The events of earlier calls still writing their summary while the next one runs.
    @ObservationIgnored private var summarising: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// What the last refresh found, so progress updates don't probe the Keychain again.
    @ObservationIgnored private var probes: ReadinessInput?
    @ObservationIgnored private var preparedLanguage: String?
    @ObservationIgnored private var eventLog = SessionEventLog()
    /// Held for the length of a call and its summary. With the window hidden Listener has
    /// nothing on screen, and App Nap would otherwise slow its timers and network work.
    @ObservationIgnored private var callActivity: (any NSObjectProtocol)?
    @ObservationIgnored private var throttle = UpdateThrottle.displayRate
    @ObservationIgnored private var markup = AnswerMarkup()
    @ObservationIgnored private let library: CallTypeLibrary
    /// The picked call type as last read off the main thread, so Start doesn't wait for
    /// its PDFs. Nil while it is being read again.
    @ObservationIgnored private var loadedCall: (name: String, context: CallContext)?
    @ObservationIgnored private var callReads = 0
    @ObservationIgnored private let callTypeWatcher = FolderWatcher()

    init(environment: AppEnvironment) {
        self.environment = environment
        library = CallTypeLibrary(paths: environment.paths)
        settings = environment.launchSettings.settings
        for warning in environment.launchSettings.warnings {
            Log.ui.notice("\(warning, privacy: .public)")
            appNotices.add(.warning, warning)
        }
        refreshReadiness()
        prepareOnDeviceSpeechIfNeeded()
        refreshCallTypes()
        finishDueSummaries()
    }

    /// A call is running or being saved, or a summary is being written.
    var hasWorkToFinish: Bool { session != nil || !summarising.isEmpty }
    var hasTranscript: Bool { !settledRows.isEmpty || !liveRows.isEmpty }

    /// Checks permissions, credentials and keys again.
    func refreshReadiness() {
        let google =
            settings.speech.provider == "google"
            ? environment.googleSetup(settings) : GoogleSetup(projectID: nil, credentialsProblem: nil)
        probes = ReadinessInput(
            microphone: CapturePermissions.microphone,
            screenRecording: settings.capture.systemAudioBackend == "sck" ? CapturePermissions.screenRecording : nil,
            systemAudioHeard: UserDefaults.standard.bool(forKey: Self.systemAudioHeardKey),
            speechProvider: settings.speech.provider,
            googleProjectID: google.projectID,
            googleCredentialsProblem: google.credentialsProblem,
            onDeviceSpeech: onDeviceSpeech,
            hasAnthropicKey: environment.hasAnthropicKey()
        )
        updateReadiness()
    }

    /// Settings changed in the main window. A running call keeps the ones it started
    /// with; the next call reads the file again anyway.
    func settingsChanged(_ settings: Settings) {
        guard !isCallRunning else {
            return
        }
        self.settings = settings
        refreshReadiness()
        prepareOnDeviceSpeechIfNeeded()
    }

    func hotkeysRegistered(_ hotkeys: [HotkeyAction: Hotkey], failures: [HotkeyRegistrationFailure]) {
        activeHotkeys = hotkeys
        for failure in failures {
            Log.ui.error("\(failure.message, privacy: .public)")
            activeHotkeys[failure.action] = nil
            appNotices.add(.warning, failure.message)
        }
    }

    func toggleListening() {
        if state.canStart {
            start()
        } else if state.canStop {
            stop()
        }
    }

    /// Starts a call. Nothing is captured until the user presses Start (or the
    /// toggle hotkey), and nothing starts while the setup checklist shows a blocker.
    /// A failed start leaves the window on the checklist with the reason on top.
    func start() {
        guard state.canStart else {
            return
        }
        state.beginStarting()
        publish()
        let loaded: LoadedSettings
        do {
            loaded = try environment.loadSettings()
        } catch {
            startFailed(ErrorText.describe(error))
            return
        }
        settings = loaded.settings
        prepareOnDeviceSpeechIfNeeded()
        refreshReadiness()
        if Readiness.blocksStart(readiness) {
            let blockers = readiness.filter { $0.status == .blocking }.map(\.detail).joined(separator: " ")
            Log.session.notice("Start blocked by the setup checklist: \(blockers, privacy: .public)")
            state.startFailed("Listener can't start yet. Fix the items marked in red below.")
            publish()
            return
        }

        let components: SessionComponents
        do {
            components = try environment.makeComponents(settings, sessionCallbacks())
        } catch {
            startFailed(ErrorText.describe(error))
            return
        }

        let call =
            loadedCall.flatMap { $0.name == callType ? $0.context : nil }
            ?? library.load(callType, readText: DocumentText.read).context
        activeCall = call
        Log.session.info(
            "Call type \(call.callType, privacy: .public) with \(call.documents.count) documents")
        let session = CallSession(settings: settings, components: components, call: call)
        if let previous = self.session, let eventsTask {
            summarising[ObjectIdentifier(previous)] = eventsTask
        }
        self.session = session
        eventLog = SessionEventLog()
        let provider = settings.speech.provider
        let backend = settings.capture.systemAudioBackend
        Log.session.info(
            "Starting a call: speech \(provider, privacy: .public), system audio \(backend, privacy: .public)")
        for warning in loaded.warnings {
            Log.session.notice("\(warning, privacy: .public)")
            state.addNotice(.warning, warning)
        }
        if components.languageModel == nil {
            Log.answers.notice("No Anthropic API key: answers and the summary are off")
            state.addNotice(.info, "Answers and the summary are off: no Anthropic API key.")
        }
        publish()
        observe(session)
        if callActivity == nil {
            callActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated, reason: "Listening to a call")
        }

        Task {
            do {
                try await session.start()
            } catch {
                guard self.session === session else {
                    return
                }
                eventsTask?.cancel()
                eventsTask = nil
                self.session = nil
                endCallActivityIfIdle()
                startFailed(ErrorText.describe(error))
                refreshReadiness()
            }
        }
    }

    func stop() {
        guard state.canStop, let session else {
            return
        }
        state.beginStopping()
        publish()
        Task {
            await session.stop()
        }
    }

    /// `pressedAt` is when the hotkey went down, or now for a button or the menu. It is
    /// taken before the hop to the session actor, so that wait counts towards the
    /// answer's latency and two quick presses keep their order.
    func ask(_ tier: AnswerTier, pressedAt: ContinuousClock.Instant = .now) {
        guard state.canAsk, let session else {
            state.addNotice(.info, "Answers need a live call. Press Start first.")
            publish()
            return
        }
        Task {
            await session.requestAnswer(tier, pressedAt: pressedAt)
        }
    }

    /// During a call the window is a slim bar with the answer card under it, unless the
    /// transcript is turned on.
    var isCompact: Bool {
        (phase == .starting || phase == .listening) && !showsTranscriptInCall
    }

    var isInCall: Bool {
        phase != .idle && phase != .finished
    }

    /// Whether an answer can be asked for now. Reads the observed phase, so views that
    /// use it redraw when a call starts.
    var canAsk: Bool {
        phase == .listening
    }

    /// Solid is fully opaque. Clear also fades the window between answers during a call,
    /// and brings it back when an answer arrives or the pointer is over it. Reads the
    /// answer's id, not the answer, so the window is not updated for every streamed word.
    var windowOpacity: Double {
        if transparency == .solid {
            return 1
        }
        if transparency == .clear && isInCall && answerID == nil && !isPointerOver {
            return WindowTransparency.clearIdleOpacity
        }
        return settings.window.opacity
    }

    func setTransparency(_ transparency: WindowTransparency) {
        self.transparency = transparency
        UserDefaults.standard.set(transparency.rawValue, forKey: WindowTransparency.key)
    }

    func toggleTranscriptInCall() {
        showsTranscriptInCall.toggle()
        UserDefaults.standard.set(showsTranscriptInCall, forKey: Self.transcriptKey)
    }

    func toggleHidingFromScreenSharing() {
        hidesFromScreenSharing.toggle()
        UserDefaults.standard.set(hidesFromScreenSharing, forKey: Self.screenSharingKey)
    }

    func pointerMoved(over: Bool) {
        isPointerOver = over
    }

    private static let transcriptKey = "showsTranscriptInCall"
    private static let screenSharingKey = "hidesFromScreenSharing"

    func dismissAnswer() {
        if state.dismissAnswer() != nil, let session {
            Task {
                await session.cancelAnswer()
            }
        }
        publish()
    }

    /// Whether the answer has words to say, beyond notes in brackets for the user.
    var canCopyAnswer: Bool {
        answerBlocks.contains { block in
            if case .note = block.kind {
                return false
            }
            return true
        }
    }

    /// Copies what to say, leaving out the notes in brackets that are only for the user.
    /// Returns whether anything was copied.
    func copyAnswer() -> Bool {
        let text = markup.textToSay
        guard !text.isEmpty else {
            return false
        }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    func dismissNotice(_ notice: Notice) {
        state.dismissNotice(id: notice.id)
        publish()
    }

    /// Leaves the finished call for the start screen, to set up the next one.
    func newCall() {
        state.clearFinishedCall()
        publish()
        refreshReadiness()
        refreshCallTypes()
    }

    /// The last call's summary, until the next call starts.
    var lastSummaryFile: String? { state.summaryFile }

    func dismissAppNotice(_ notice: Notice) {
        appNotices.dismiss(id: notice.id)
    }

    /// A banner about the app from outside the window, such as dictation's setup.
    func addAppNotice(_ kind: Notice.Kind, _ message: String, action: NoticeAction? = nil) {
        appNotices.add(kind, message, action: action)
    }

    func removeAppNotice(_ message: String) {
        for notice in appNotices.items where notice.message == message {
            appNotices.dismiss(id: notice.id)
        }
    }

    /// A call is starting, running or being saved.
    var isCallRunning: Bool { !state.canStart }

    func perform(_ action: NoticeAction) {
        switch action {
        case .revealInFinder(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .openFile(let path):
            Self.openTextFile(URL(fileURLWithPath: path))
        case .openURL(let link, _):
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func perform(_ fix: ReadinessFix) {
        switch fix {
        case .openPrivacySettings(let pane):
            if let url = URL(string: pane.url) {
                NSWorkspace.shared.open(url)
            }
        case .editSettings:
            openSettingsFile()
        case .runInTerminal(let command):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.runnable(command), forType: .string)
            appNotices.add(.info, "Copied \"\(command)\". Paste it into Terminal, then press Check Again.")
        }
    }

    /// Opens settings.json or summary.md in the app the user picked for that kind of
    /// file. A Mac without Xcode or a code editor may have no app for .json or .md,
    /// and then the file opens in TextEdit instead of not at all.
    private static func openTextFile(_ file: URL) {
        let workspace = NSWorkspace.shared
        if workspace.urlForApplication(toOpen: file) != nil {
            workspace.open(file)
            return
        }
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        workspace.open([file], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }

    /// `listener` is not on the PATH, so a command for it is copied with the full path
    /// of this binary. That also makes the Keychain item the command stores readable by
    /// the app without a prompt, because the same binary wrote it.
    private static func runnable(_ command: String) -> String {
        let prefix = "listener "
        guard command.hasPrefix(prefix), let executable = Bundle.main.executablePath else {
            return command
        }
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return quoted + " " + command.dropFirst(prefix.count)
    }

    func openSettingsFile() {
        do {
            let file = try SettingsLoader(paths: environment.paths).createSettingsFileIfMissing()
            Self.openTextFile(file)
        } catch {
            appNotices.add(.error, "Could not create settings.json: \(ErrorText.describe(error))")
        }
    }

    func openSessionsFolder() {
        let directory = SessionStore.root(for: settings.storage, paths: environment.paths)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            appNotices.add(.error, "Could not open \(directory.path): \(ErrorText.describe(error))")
        }
    }

    /// Stops a running call and waits until it is saved and every summary being written
    /// is done, for quitting.
    func finishForQuit() async {
        if let session {
            if state.canStop {
                stop()
            } else if state.phase == .starting {
                await session.stop()
            }
        }
        await eventsTask?.value
        for task in summarising.values {
            await task.value
        }
    }

    /// Summaries that were being written when Listener last quit or crashed.
    private func finishDueSummaries() {
        let environment = environment
        let settings = settings
        Task {
            for file in await environment.finishDueSummaries(settings) {
                Log.session.info("Wrote a summary left unfinished last time")
                appNotices.add(
                    .info, "The summary Listener was writing when it quit is ready.", action: .openFile(path: file.path)
                )
            }
            dueSummariesFinished += 1
        }
    }

    private static let systemAudioHeardKey = "systemAudioHeard"
    private static let callTypeKey = "callType"

    /// Reads the call types again, for when the window shows: files may have changed in
    /// Finder or TextEdit while it was hidden.
    func refreshCallTypes() {
        do {
            try library.createIfMissing()
        } catch {
            appNotices.add(.error, "Could not create the Call Types folder: \(ErrorText.describe(error))")
        }
        callTypes = library.names()
        let saved = UserDefaults.standard.string(forKey: Self.callTypeKey)
        callType =
            [saved, callType, CallTypeLibrary.defaultType].compactMap { $0 }.first(where: callTypes.contains)
            ?? callTypes.first ?? CallTypeLibrary.defaultType
        watchCallType()
    }

    /// The call type for the next call. A running call keeps the one it started with.
    func selectCallType(_ name: String) {
        guard callTypes.contains(name) else {
            return
        }
        callType = name
        UserDefaults.standard.set(name, forKey: Self.callTypeKey)
        watchCallType()
    }

    /// Copies files dropped on the window into the call type's folder.
    func addFiles(_ urls: [URL]) {
        let readable = urls.filter(DocumentText.canRead)
        if readable.count < urls.count {
            appNotices.add(.warning, "Listener reads \(DocumentText.kinds). Other files were left out.")
        }
        guard !readable.isEmpty else {
            return
        }
        do {
            try library.add(files: readable, to: callType)
        } catch {
            appNotices.add(.error, "Could not add the files: \(ErrorText.describe(error))")
        }
        reloadCallFiles()
    }

    /// Adds whatever is on the clipboard: copied files, a link to read, or text.
    func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        if let files = files as? [URL], !files.isEmpty {
            addFiles(files)
            return
        }
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            appNotices.add(.info, "The clipboard is empty. Copy a job description, or its link, then press Paste.")
            return
        }
        if !text.contains(where: \.isWhitespace), let url = URL(string: text),
            ["http", "https"].contains(url.scheme?.lowercased())
        {
            importPage(url)
            return
        }
        do {
            try library.add(text: text, to: callType)
        } catch {
            appNotices.add(.error, "Could not save the pasted text: \(ErrorText.describe(error))")
        }
        reloadCallFiles()
    }

    func editBrief() {
        do {
            Self.openTextFile(try library.createBriefIfMissing(for: callType))
        } catch {
            appNotices.add(.error, "Could not create the brief: \(ErrorText.describe(error))")
        }
    }

    func editStories() {
        do {
            Self.openTextFile(try library.createStoriesIfMissing(for: callType))
        } catch {
            appNotices.add(.error, "Could not create the stories file: \(ErrorText.describe(error))")
        }
    }

    func editCallTypeInstructions() {
        Self.openTextFile(library.folder(for: callType).appendingPathComponent(CallTypeLibrary.instructionsFile))
    }

    func revealCallTypes() {
        NSWorkspace.shared.activateFileViewerSelecting([library.folder(for: callType)])
    }

    /// Moves a file to the Bin, so a mistake can be undone in Finder.
    func removeCallFile(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            appNotices.add(.error, "Could not move \(url.lastPathComponent) to the Bin: \(ErrorText.describe(error))")
        }
        reloadCallFiles()
    }

    private func importPage(_ url: URL) {
        guard !isImportingPage else {
            return
        }
        isImportingPage = true
        let name = callType
        let settings = settings
        Task {
            do {
                let markdown = try await environment.importWebPage(url, settings)
                try library.add(text: markdown, to: name)
            } catch {
                Log.ui.notice("Reading \(url.host() ?? "a link", privacy: .public) failed")
                appNotices.add(.warning, ErrorText.describe(error))
            }
            isImportingPage = false
            reloadCallFiles()
        }
    }

    private func watchCallType() {
        callTypeWatcher.watch(library.folder(for: callType)) { [weak self] in
            self?.reloadCallFiles()
        }
        reloadCallFiles()
    }

    /// Reads the files off the main thread: a long PDF takes a moment.
    private func reloadCallFiles() {
        let library = library
        let name = callType
        loadedCall = nil
        callReads += 1
        let read = callReads
        Task {
            let loaded = await Task.detached { library.load(name, readText: DocumentText.read) }.value
            // A newer read has begun if the files changed meanwhile; this one is stale.
            if callType == name, read == callReads {
                callFiles = loaded.files
                loadedCall = (name, loaded.context)
            }
        }
    }

    /// macOS has no way to ask whether System Audio Recording is allowed, but the tap
    /// only ever hears speech when it is, so the first speech from "Them" settles it.
    private func noteSystemAudioHeard(_ event: SessionEvent) {
        guard case .channelActivity(.them, isSpeaking: true) = event, settings.capture.systemAudioBackend == "tap",
            probes?.systemAudioHeard == false
        else {
            return
        }
        UserDefaults.standard.set(true, forKey: Self.systemAudioHeardKey)
        probes?.systemAudioHeard = true
        updateReadiness()
    }

    private func updateReadiness() {
        guard var input = probes else {
            return
        }
        input.onDeviceSpeech = onDeviceSpeech
        readiness = Readiness.check(input)
    }

    /// Gets Apple's on-device model ready as soon as it is the chosen provider, so
    /// the first call doesn't wait for a download. Runs again after a failure or
    /// when the language changes.
    private func prepareOnDeviceSpeechIfNeeded() {
        guard settings.speech.provider == "apple" else {
            return
        }
        let language = settings.speech.languageCode
        let failed = if case .failed = onDeviceSpeech { true } else { false }
        if preparedLanguage == language && !failed {
            return
        }
        preparedLanguage = language
        onDeviceSpeechChanged(.checking)
        let settings = settings
        let prepare = environment.prepareOnDeviceSpeech
        Task { [weak self] in
            await prepare(settings) { status in
                Task { @MainActor in
                    self?.onDeviceSpeechChanged(status)
                }
            }
        }
    }

    private func onDeviceSpeechChanged(_ status: OnDeviceSpeechStatus) {
        switch status {
        case .checking:
            break
        case .downloading:
            if case .downloading = onDeviceSpeech {
                break
            }
            Log.speech.info("Downloading the on-device speech model")
        case .ready(let locale):
            if onDeviceSpeech != status {
                Log.speech.info("On-device speech ready for \(locale, privacy: .public)")
            }
        case .failed(let message):
            Log.speech.error("On-device speech unavailable: \(message, privacy: .public)")
        }
        onDeviceSpeech = status
        updateReadiness()
    }

    private func endCallActivityIfIdle() {
        guard !hasWorkToFinish, let callActivity else {
            return
        }
        ProcessInfo.processInfo.endActivity(callActivity)
        self.callActivity = nil
    }

    private func startFailed(_ message: String) {
        Log.session.error("Could not start the call: \(message, privacy: .public)")
        state.startFailed(message)
        publish()
    }

    /// Forwards what capture and speech report on their own to the window.
    private func sessionCallbacks() -> SessionCallbacks {
        SessionCallbacks(
            captureEvent: { [weak self] event in
                Task { @MainActor in
                    self?.state.apply(event)
                    self?.publish()
                }
            },
            onDeviceSpeech: { [weak self] status in
                Task { @MainActor in
                    self?.onDeviceSpeechChanged(status)
                }
            }
        )
    }

    private func observe(_ session: CallSession) {
        eventsTask = Task { [weak self] in
            for await event in session.events {
                self?.receive(event, from: session)
            }
            self?.eventsEnded(for: session)
        }
    }

    private func receive(_ event: SessionEvent, from session: CallSession) {
        guard session === self.session else {
            receiveFromEarlierCall(event)
            return
        }
        eventLog.record(event)
        noteSystemAudioHeard(event)
        state.apply(event, now: Date())
        switch throttle.request(at: ProcessInfo.processInfo.systemUptime) {
        case .now:
            publish()
        case .after(let delay):
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.publish()
            }
        case .alreadyScheduled:
            break
        }
    }

    /// Copies whatever changed in `state` into the observed slices.
    private func publish() {
        throttle.didUpdate(at: ProcessInfo.processInfo.systemUptime)
        update(\.phase, state.phase)
        update(\.listeningSince, state.listeningSince)
        if state.settledRows != settledRows || state.liveRows != liveRows {
            update(\.settledRows, state.settledRows)
            update(\.liveRows, state.liveRows)
            transcriptRevision += 1
        }
        if state.answer != answer {
            if state.answer?.id != answer?.id {
                markup = AnswerMarkup()
            }
            markup.update(state.answer?.text ?? "")
            answer = state.answer
            update(\.answerID, state.answer?.id)
            update(\.answerBlocks, markup.blocks)
        }
        update(\.callNotices, state.notices)
        update(\.cost, state.cost)
        update(\.lastLatencyMs, state.lastLatencyMs)
        update(\.outcome, state.outcome)
        update(\.hearing, state.hearing)
    }

    private func update<Value: Equatable>(_ slice: ReferenceWritableKeyPath<CallModel, Value>, _ value: Value) {
        if self[keyPath: slice] != value {
            self[keyPath: slice] = value
        }
    }

    /// The summary of a call that ended before the one on screen.
    private func receiveFromEarlierCall(_ event: SessionEvent) {
        switch event {
        case .summaryFinished(let file?):
            appNotices.add(.info, "The last call's summary is ready.", action: .openFile(path: file))
        case .warning(let message):
            appNotices.add(.warning, message)
        default:
            break
        }
    }

    private func eventsEnded(for session: CallSession) {
        summarising[ObjectIdentifier(session)] = nil
        if self.session === session {
            self.session = nil
            eventsTask = nil
            state.eventsEnded()
            publish()
        }
        endCallActivityIfIdle()
    }
}
