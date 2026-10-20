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

        showWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A running call is stopped and saved before quitting. Saving normally takes a
    /// few seconds; a stuck provider never holds the quit for more than 30.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasSession else {
            return .terminateNow
        }
        if !terminationPending {
            terminationPending = true
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
