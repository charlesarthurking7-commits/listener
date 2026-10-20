import Dispatch
import Foundation
import ListenerCore

/// Terminal input and output for the subcommands.
enum Console {
    static func write(_ text: String) {
        if !text.isEmpty {
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }

    static func error(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static var inputIsTerminal: Bool { isatty(STDIN_FILENO) == 1 }

    /// Colours and a rewritten live line only on a real terminal.
    static var style: TerminalStyle {
        let environment = ProcessInfo.processInfo.environment
        let terminal = isatty(STDOUT_FILENO) == 1
        let color = terminal && environment["NO_COLOR"] == nil && environment["TERM"] != "dumb"
        let width = environment["COLUMNS"].flatMap(Int.init) ?? 100
        return TerminalStyle(color: color, liveLine: terminal, width: width)
    }

    /// Lines typed on standard input. readLine blocks, so it runs on its own thread.
    static func typedLines() -> AsyncStream<String> {
        AsyncStream { continuation in
            Thread {
                while let line = readLine() {
                    continuation.yield(line)
                }
                continuation.finish()
            }.start()
        }
    }

    /// Reads one line without echoing it, for pasting secrets. Works with piped
    /// input too, where there is nothing to hide.
    static func readHiddenLine() -> String? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            return readLine()
        }
        terminalBeforeHiddenInput = original
        // Ctrl-C would otherwise leave the terminal without echo.
        signal(SIGINT) { _ in
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &terminalBeforeHiddenInput)
            _exit(130)
        }
        var hidden = original
        hidden.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden)
        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            signal(SIGINT, SIG_DFL)
            write("\n")
        }
        return readLine()
    }
}

/// The terminal settings to restore if Ctrl-C interrupts hidden input. A signal handler
/// cannot capture context, so it lives here; only set before that handler is installed.
private nonisolated(unsafe) var terminalBeforeHiddenInput = termios()

/// Ctrl-C as a stream of events instead of the default of killing the process,
/// so a running call can be stopped and saved.
final class InterruptSignal: @unchecked Sendable {
    let events: AsyncStream<Void>
    // Only touched in init; kept so the source lives as long as this object.
    private let source: any DispatchSourceSignal

    init() {
        signal(SIGINT, SIG_IGN)
        let (events, continuation) = AsyncStream.makeStream(of: Void.self)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            continuation.yield()
        }
        source.resume()
        self.events = events
        self.source = source
    }
}
