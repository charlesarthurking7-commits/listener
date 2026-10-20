import AppKit
import ListenerCore
import Observation
import os

/// The window's model: owns the running CallSession and reduces its events into
/// `state`. All the reduction logic lives in CallViewState (ListenerCore), this class
/// only connects it to the session, the settings and AppKit.
@MainActor
@Observable
public final class CallModel {
    public private(set) var state = CallViewState()
    public private(set) var readiness: [ReadinessItem] = []
    /// Banners about the app rather than the call, e.g. a hotkey that is taken.
    public private(set) var appNotices = NoticeList()
    /// Hotkeys that registered, for the footer and the menu.
    public private(set) var activeHotkeys: [HotkeyAction: Hotkey] = [:]
    public private(set) var settings: Settings
    /// The on-device model's state when speech.provider is "apple".
    public private(set) var onDeviceSpeech: OnDeviceSpeechStatus?

    /// Called whenever listening starts or stops, for the menu bar icon.
    @ObservationIgnored public var onListeningChange: ((Bool) -> Void)?

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var session: CallSession?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    /// What the last refresh found, so progress updates don't probe the Keychain again.
    @ObservationIgnored private var probes: ReadinessInput?
    @ObservationIgnored private var preparedLanguage: String?
    @ObservationIgnored private var eventLog = SessionEventLog()
    /// Held for the length of a call. With the window hidden Listener has nothing on
    /// screen, and App Nap would otherwise slow its timers and network work mid-call.
    @ObservationIgnored private var callActivity: (any NSObjectProtocol)?

    public init(environment: AppEnvironment) {
        self.environment = environment
        settings = environment.launchSettings.settings
        for warning in environment.launchSettings.warnings {
            Log.ui.notice("\(warning, privacy: .public)")
            appNotices.add(.warning, warning)
        }
        refreshReadiness()
        prepareOnDeviceSpeechIfNeeded()
    }

    public var hasSession: Bool { session != nil }

    /// Checks permissions, credentials and keys again.
    public func refreshReadiness() {
        let google =
            settings.speech.provider == "google"
            ? environment.googleSetup(settings) : GoogleSetup(projectID: nil, credentialsProblem: nil)
        probes = ReadinessInput(
            microphone: SystemPermissions.microphone,
            screenRecording: settings.capture.systemAudioBackend == "sck" ? SystemPermissions.screenRecording : nil,
            speechProvider: settings.speech.provider,
            googleProjectID: google.projectID,
            googleCredentialsProblem: google.credentialsProblem,
            onDeviceSpeech: onDeviceSpeech,
            hasAnthropicKey: environment.hasAnthropicKey()
        )
        updateReadiness()
    }

    public func hotkeysRegistered(_ hotkeys: [HotkeyAction: Hotkey], failures: [HotkeyRegistrationFailure]) {
        activeHotkeys = hotkeys
        for failure in failures {
            Log.ui.error("\(failure.message, privacy: .public)")
            activeHotkeys[failure.action] = nil
            appNotices.add(.warning, failure.message)
        }
    }

    public func toggleListening() {
        if state.canStart {
            start()
        } else if state.canStop {
            stop()
        }
    }

    /// Starts a call. Nothing is captured until the user presses Start (or the
    /// toggle hotkey), and nothing starts while the setup checklist shows a blocker.
    /// A failed start leaves the window on the checklist with the reason on top.
    public func start() {
        guard state.canStart else {
            return
        }
        state.beginStarting()
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
            return
        }

        let components: SessionComponents
        do {
            components = try environment.makeComponents(settings, sessionCallbacks())
        } catch {
            startFailed(ErrorText.describe(error))
            return
        }

        let session = CallSession(settings: settings, components: components)
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
        observe(session)
        callActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated, reason: "Listening to a call")

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
                endCallActivity()
                startFailed(ErrorText.describe(error))
                refreshReadiness()
            }
        }
    }

    public func stop() {
        guard state.canStop, let session else {
            return
        }
        state.beginStopping()
        onListeningChange?(false)
        Task {
            await session.stop()
        }
    }

    public func ask(_ tier: AnswerTier) {
        guard state.canAsk, let session else {
            state.addNotice(.info, "Answers need a live call. Press Start first.")
            return
        }
        Task {
            await session.requestAnswer(tier)
        }
    }

    public func dismissAnswer() {
        if state.dismissAnswer() != nil, let session {
            Task {
                await session.cancelAnswer()
            }
        }
    }

    public func copyAnswer() {
        guard let text = state.answer?.text, !text.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func dismissNotice(_ notice: Notice) {
        state.dismissNotice(id: notice.id)
    }

    public func dismissAppNotice(_ notice: Notice) {
        appNotices.dismiss(id: notice.id)
    }

    public func perform(_ action: NoticeAction) {
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

    public func perform(_ fix: ReadinessFix) {
        switch fix {
        case .openPrivacySettings(let pane):
            SystemPermissions.open(pane)
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

    public func openSettingsFile() {
        do {
            let file = try SettingsLoader(paths: environment.paths).createSettingsFileIfMissing()
            Self.openTextFile(file)
        } catch {
            appNotices.add(.error, "Could not create settings.json: \(ErrorText.describe(error))")
        }
    }

    public func openSessionsFolder() {
        let directory = environment.sessionsDirectory(settings)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            appNotices.add(.error, "Could not open \(directory.path): \(ErrorText.describe(error))")
        }
    }

    /// Stops a running call and waits until it is saved, for quitting.
    public func finishForQuit() async {
        guard let session else {
            return
        }
        if state.canStop {
            stop()
        } else if state.phase == .starting {
            await session.stop()
        }
        await eventsTask?.value
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

    private func endCallActivity() {
        if let callActivity {
            ProcessInfo.processInfo.endActivity(callActivity)
        }
        callActivity = nil
    }

    private func startFailed(_ message: String) {
        Log.session.error("Could not start the call: \(message, privacy: .public)")
        state.startFailed(message)
    }

    /// Forwards what capture and speech report on their own to the window.
    private func sessionCallbacks() -> SessionCallbacks {
        SessionCallbacks(
            captureEvent: { [weak self] event in
                Task { @MainActor in
                    self?.state.apply(event)
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
                self?.receive(event)
            }
            self?.eventsEnded(for: session)
        }
    }

    private func receive(_ event: SessionEvent) {
        eventLog.record(event)
        let wasListening = state.isListening
        state.apply(event, now: Date())
        if state.isListening != wasListening {
            onListeningChange?(state.isListening)
        }
    }

    private func eventsEnded(for session: CallSession) {
        guard self.session === session else {
            return
        }
        self.session = nil
        eventsTask = nil
        endCallActivity()
        state.eventsEnded()
        onListeningChange?(false)
    }
}
