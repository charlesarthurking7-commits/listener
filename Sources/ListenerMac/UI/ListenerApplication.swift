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
    private var quitSignals: [any DispatchSourceSignal] = []
    private var terminationPending = false

    init(environment: AppEnvironment) {
        self.environment = environment
        model = CallModel(environment: environment)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = environment.launchSettings.settings
        let rootView = ListenerWindowView(
            model: model,
            hide: { [weak self] in self?.panel?.orderOut(nil) },
            fitHeight: { [weak self] in self?.panel?.fitContent(height: $0) })
        panel = FloatingPanel(rootView: rootView, window: settings.window)
        followWindowState()

        statusItem = StatusItemController(
            model: model,
            actions: .init(
                showWindow: { [weak self] in self?.showWindow() },
                toggleWindow: { [weak self] in self?.toggleWindow() },
                isWindowVisible: { [weak self] in self?.panel?.isVisible ?? false },
                moveWindowToTopCentre: { [weak self] in
                    self?.showWindow()
                    self?.panel?.moveToTopCentre()
                },
                quit: { NSApplication.shared.terminate(nil) }
            )
        )
        model.onListeningChange = { [weak self] listening in
            self?.statusItem?.update(listening: listening)
        }

        let hotkeys = HotkeyCenter { [weak self] action in
            self?.handle(action)
        }
        let wanted = settings.hotkeys.hotkeys
        model.hotkeysRegistered(wanted, failures: hotkeys.register(wanted))
        self.hotkeys = hotkeys

        quitOnSignals()
        // The model checked the setup a moment ago; checking again would read the
        // Keychain twice at launch.
        panel?.show()
        Log.ui.info("Listener started")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Opening the app again (Finder, `open`, the Dock icon) brings back a hidden window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    /// A running call is stopped and saved before quitting. Saving normally takes a
    /// few seconds; a stuck provider never holds the quit for more than 30.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasSession else {
            return .terminateNow
        }
        if !terminationPending {
            terminationPending = true
            Log.session.notice("Quitting during a call: saving it first")
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

    /// Keeps the panel's transparency and screen sharing in step with the model, which
    /// changes them as calls start and stop, answers come and go, and the pointer moves.
    private func followWindowState() {
        withObservationTracking {
            panel?.apply(
                transparency: model.transparency, opacity: model.windowOpacity,
                hiddenFromSharing: model.hidesFromScreenSharing)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followWindowState()
            }
        }
    }

    private func handle(_ action: HotkeyAction) {
        switch action {
        case .quickAnswer:
            panel?.show()
            model.ask(.quick)
        case .deepAnswer:
            panel?.show()
            model.ask(.deep)
        case .recap:
            panel?.show()
            model.ask(.recap)
        case .toggleWindow:
            toggleWindow()
        case .toggleListening:
            // Start checks the setup itself.
            model.toggleListening()
            panel?.show()
        }
    }
}
