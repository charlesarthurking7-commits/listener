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
    private var quitSignals: [any DispatchSourceSignal] = []
    private var terminationPending = false

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
            hide: { [weak self] in self?.panel?.orderOut(nil) },
            fitHeight: { [weak self] in self?.panel?.fitContent(height: $0) })
        panel = FloatingPanel(rootView: rootView, window: settings.window, room: room)

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
                quit: { NSApplication.shared.terminate(nil) }
            )
        )
        followWindowState()

        let hotkeys = HotkeyCenter { [weak self] action, pressedAt in
            self?.handle(action, pressedAt: pressedAt)
        }
        let wanted = settings.hotkeys.hotkeys
        model.hotkeysRegistered(wanted, failures: hotkeys.register(wanted))
        self.hotkeys = hotkeys
        setUpDictation(dictation)

        quitOnSignals()
        // The model checked the setup a moment ago; checking again would read the
        // Keychain twice at launch.
        panel?.show()
        Log.ui.info("Listener started")
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

    /// Opening the app again (Finder, `open`, the Dock icon) brings back a hidden window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
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

    private func toggleWindow() {
        if panel?.isVisible == true {
            panel?.orderOut(nil)
        } else {
            showWindow()
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
