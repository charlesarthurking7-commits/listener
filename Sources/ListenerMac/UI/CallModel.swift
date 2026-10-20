import AppKit
import ListenerCore
import Observation

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

    /// Called whenever listening starts or stops, for the menu bar icon.
    @ObservationIgnored public var onListeningChange: ((Bool) -> Void)?

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var session: CallSession?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    public init(environment: AppEnvironment) {
        self.environment = environment
        settings = environment.launchSettings.settings
        for warning in environment.launchSettings.warnings {
            appNotices.add(.warning, warning)
        }
        refreshReadiness()
    }

    public var hasSession: Bool { session != nil }

    public func refreshReadiness() {
        let input = ReadinessInput(
            microphone: SystemPermissions.microphone(),
            screenRecording: settings.capture.systemAudioBackend == "sck" ? SystemPermissions.screenRecording() : nil,
            speechProvider: settings.speech.provider,
            googleProjectID: settings.speech.googleProjectID,
            googleCredentialsProblem: environment.speechCredentialsProblem(settings),
            hasAnthropicKey: environment.hasAnthropicKey()
        )
        readiness = Readiness.check(input)
    }

    public func hotkeysRegistered(_ hotkeys: [HotkeyAction: Hotkey], failures: [HotkeyRegistrationFailure]) {
        activeHotkeys = hotkeys
        for failure in failures {
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
            state.startFailed(ErrorText.describe(error))
            return
        }
        settings = loaded.settings
        refreshReadiness()
        if Readiness.blocksStart(readiness) {
            state.startFailed("Listener can't start yet. Fix the items marked in red below.")
            return
        }

        let components: SessionComponents
        do {
            components = try environment.makeComponents(settings)
        } catch {
            state.startFailed(ErrorText.describe(error))
            return
        }

        let session = CallSession(settings: settings, components: components)
        self.session = session
        for warning in loaded.warnings {
            state.addNotice(.warning, warning)
        }
        if components.languageModel == nil {
            state.addNotice(.info, "Answers and the summary are off: no Anthropic API key.")
        }
        observe(session)

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
                state.startFailed(ErrorText.describe(error))
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
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
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
            NSPasteboard.general.setString(command, forType: .string)
            appNotices.add(.info, "Copied \"\(command)\". Paste it into Terminal, then press Check Again.")
        }
    }

    public func openSettingsFile() {
        do {
            let file = try SettingsLoader(paths: environment.paths).createSettingsFileIfMissing()
            NSWorkspace.shared.open(file)
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

    private func observe(_ session: CallSession) {
        eventsTask = Task { [weak self] in
            for await event in session.events {
                self?.receive(event)
            }
            self?.eventsEnded(for: session)
        }
    }

    private func receive(_ event: SessionEvent) {
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
        state.eventsEnded()
        onListeningChange?(false)
    }
}
