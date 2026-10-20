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
        let rootView = ListenerWindowView(model: model) { [weak self] in
            self?.panel?.orderOut(nil)
        }
        panel = FloatingPanel(rootView: rootView, window: settings.window)

        statusItem = StatusItemController(
            model: model,
            actions: .init(
                showWindow: { [weak self] in self?.showWindow() },
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
        showWindow()
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
        }
        panel?.show()
    }

    private func handle(_ action: HotkeyAction) {
        switch action {
        case .quickAnswer:
            showWindow()
            model.ask(.quick)
        case .deepAnswer:
            showWindow()
            model.ask(.deep)
        case .toggleListening:
            model.toggleListening()
            showWindow()
        }
    }
}
