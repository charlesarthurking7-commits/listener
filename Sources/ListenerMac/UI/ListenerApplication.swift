import AppKit
import ListenerCore

/// The menu bar app with its floating window.
@MainActor
public enum ListenerApplication {
    /// Runs the app on the main thread until it quits. Must be called from the
    /// program's synchronous entry point, not from inside a Task or a dispatch block,
    /// or the main queue (and with it the main actor) would never be drained.
    public static func run(environment: AppEnvironment) -> Never {
        let app = NSApplication.shared
        Fonts.register()
        if let appearance = environment.appearance {
            app.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        let delegate = AppDelegate(environment: environment)
        app.delegate = delegate
        app.setActivationPolicy(environment.launchSettings.settings.window.showDockIcon ? .regular : .accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
        exit(0)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment: AppEnvironment
    private let model: CallModel
    private var panel: FloatingPanel?
    private var statusItem: StatusItemController?
    private var hotkeys: HotkeyCenter?
    private var dictation: DictationController?
    private var dictationPill: DictationPill?
    private var mainWindow: MainWindowController?
    private var quitSignals: [any DispatchSourceSignal] = []
    private var terminationPending = false
    private var shownPhase = CallViewState.Phase.idle

    init(environment: AppEnvironment) {
        self.environment = environment
        model = CallModel(environment: environment)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = environment.launchSettings.settings
        let room = PanelRoom()
        let rootView = ListenerWindowView(
            model: model, room: room,
            hide: { [weak self] in self?.hideWindow() },
            showMain: { [weak self] in self?.showMainWindow(nil, call: $0) },
            fitHeight: { [weak self] in self?.panel?.fitContent(height: $0) })
        panel = FloatingPanel(rootView: rootView, window: settings.window, room: room)
        model.showMain = { [weak self] call in self?.showMainWindow(.calls, call: call, setup: call == nil) }

        let dictation = DictationController(environment: environment) { [model] in model.isCallRunning }
        self.dictation = dictation
        statusItem = StatusItemController(
            model: model,
            dictation: dictation,
            actions: .init(
                toggleWindow: { [weak self] in self?.toggleWindow() },
                isWindowVisible: { [weak self] in self?.panel?.isVisible ?? false },
                moveWindowToTopCentre: { [weak self] in
                    self?.showWindow()
                    self?.panel?.moveToTopCentre()
                },
                openMainWindow: { [weak self] in self?.showMainWindow($0) },
                quit: { NSApplication.shared.terminate(nil) }
            )
        )
        followWindowState()
        followCallPhase()

        let hotkeys = HotkeyCenter { [weak self] action, pressedAt in
            self?.handle(action, pressedAt: pressedAt)
        }
        let wanted = settings.hotkeys.hotkeys
        model.hotkeysRegistered(wanted, failures: hotkeys.register(wanted))
        self.hotkeys = hotkeys
        setUpDictation(dictation)
        NSApp.mainMenu = MainMenu.make(
            openSettings: { [weak self] in self?.showMainWindow(.settings) },
            showSection: { [weak self] in self?.showMainWindow($0) })

        quitOnSignals()
        // The floating window waits for a call. Opened at login Listener waits in the menu
        // bar too, unless a call can't start yet: then the main window says what is missing.
        if let name = environment.mainWindowAtLaunch {
            showMainWindow(MainWindowModel.Section(argument: name))
        } else if Readiness.blocksStart(model.readiness) {
            showMainWindow(.calls, setup: true)
        } else if !Self.launchedAtLogin {
            showMainWindow(nil)
        }
        Log.ui.info("Listener started")
    }

    private static var launchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// The pill, and banners for what macOS still has to allow.
    private func setUpDictation(_ dictation: DictationController) {
        guard dictation.isEnabled else {
            return
        }
        dictationPill = DictationPill(controller: dictation)
        DictationSetup.requestAccessibilityOnce()
        if !dictation.isWatchingFn {
            model.addAppNotice(.warning, DictationSetup.accessibilityNotice, action: DictationSetup.accessibilityAction)
            dictation.onWatchingFn = { [model] in
                model.removeAppNotice(DictationSetup.accessibilityNotice)
            }
        }
        if !DictationSetup.fnKeyIsFree {
            model.addAppNotice(.info, DictationSetup.fnKeyNotice, action: DictationSetup.keyboardAction)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Opening the app again (Finder, `open`, the Dock icon) opens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(nil)
        return false
    }

    /// A running call is stopped and saved, and its summary written, before quitting.
    /// Neither ever holds the quit for more than 30 s: a summary cut off then is written
    /// at the next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasWorkToFinish else {
            return .terminateNow
        }
        if !terminationPending {
            terminationPending = true
            Log.session.notice("Quitting during a call or its summary: finishing it first")
            Task {
                await model.finishForQuit()
                replyToTermination()
            }
            Task {
                try? await Task.sleep(for: .seconds(30))
                replyToTermination()
            }
        }
        return .terminateLater
    }

    /// `kill`, or Ctrl-C in the terminal that started the app, quits like the menu
    /// does, so a running call is saved first. A second signal quits at once.
    private func quitOnSignals() {
        for number in [SIGTERM, SIGINT] {
            // A handler that does nothing rather than SIG_IGN: ignoring would be
            // inherited by child processes such as gcloud, and they could no longer be
            // stopped with SIGTERM.
            signal(number) { _ in }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.quitFromSignal()
                }
            }
            source.resume()
            quitSignals.append(source)
        }
    }

    private func quitFromSignal() {
        if terminationPending {
            exit(1)
        }
        Log.ui.notice("Quitting on a signal")
        NSApplication.shared.terminate(nil)
    }

    private func replyToTermination() {
        guard terminationPending else {
            return
        }
        terminationPending = false
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }

    private func showWindow() {
        if !model.state.isListening {
            model.refreshReadiness()
            model.refreshCallTypes()
        }
        panel?.show()
    }

    /// A saved call's bar has done its job once hidden, so the next show is the start bar.
    private func hideWindow() {
        panel?.orderOut(nil)
        if model.phase == .finished {
            model.newCall()
        }
    }

    /// Made the first time it is asked for, so a call-only session never builds it.
    /// `setup` opens it on the setup checklist, which shows while no call is picked.
    private func showMainWindow(_ section: MainWindowModel.Section?, call: URL? = nil, setup: Bool = false) {
        guard let dictation else {
            return
        }
        if mainWindow == nil {
            let model = MainWindowModel(call: model, dictation: dictation, environment: environment)
            model.store.onChange = { [weak self] in self?.apply($0) }
            model.settings.pauseHotkeys = { [weak self] in self?.pauseHotkeys($0) }
            model.calls.showFloatingWindow = { [weak self] in self?.showWindow() }
            mainWindow = MainWindowController(model: model)
        }
        mainWindow?.show(call == nil ? section : .calls)
        if let call {
            mainWindow?.model.calls.show(call)
        } else if setup {
            mainWindow?.model.calls.showSetup()
        }
    }

    /// Applies what can change without a restart as soon as Settings saves it: the
    /// hotkeys and the floating window. The rest applies from the next call.
    private func apply(_ settings: Settings) {
        let hotkeysChanged = settings.hotkeys != model.settings.hotkeys
        model.settingsChanged(settings)
        panel?.apply(window: settings.window)
        if hotkeysChanged, let hotkeys {
            let wanted = settings.hotkeys.hotkeys
            model.hotkeysRegistered(wanted, failures: hotkeys.register(wanted))
        }
    }

    /// While a shortcut is being recorded, pressing it must reach the recorder, not run.
    private func pauseHotkeys(_ paused: Bool) {
        guard let hotkeys else {
            return
        }
        if paused {
            _ = hotkeys.register([:])
        } else {
            let wanted = model.settings.hotkeys.hotkeys
            model.hotkeysRegistered(wanted, failures: hotkeys.register(wanted))
        }
    }

    private func toggleWindow() {
        if panel?.isVisible == true {
            hideWindow()
        } else {
            showWindow()
        }
    }

    /// The floating window comes up for every call, however it was started: the hotkey,
    /// the menu bar or the main window.
    private func followCallPhase() {
        withObservationTracking {
            let phase = model.phase
            if phase != shownPhase {
                shownPhase = phase
                // Start has just checked the setup, so this skips the check showWindow makes.
                if phase == .starting {
                    panel?.show()
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followCallPhase()
            }
        }
    }

    /// Keeps the panel and the menu bar icon in step with the model, which changes them as
    /// calls start and stop, answers come and go, and the pointer moves.
    private func followWindowState() {
        withObservationTracking {
            panel?.apply(
                transparency: model.transparency, opacity: model.windowOpacity,
                hiddenFromSharing: model.hidesFromScreenSharing)
            statusItem?.update(listening: model.phase == .listening, hiddenFromSharing: model.hidesFromScreenSharing)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followWindowState()
            }
        }
    }

    /// Asks first and shows the window after, so the request leaves as soon as it can.
    private func handle(_ action: HotkeyAction, pressedAt: ContinuousClock.Instant) {
        switch action {
        case .quickAnswer:
            model.ask(.quick, pressedAt: pressedAt)
            panel?.show()
        case .deepAnswer:
            model.ask(.deep, pressedAt: pressedAt)
            panel?.show()
        case .recap:
            model.ask(.recap, pressedAt: pressedAt)
            panel?.show()
        case .toggleWindow:
            toggleWindow()
        case .toggleListening:
            // Start checks the setup itself.
            model.toggleListening()
            panel?.show()
        }
    }
}
