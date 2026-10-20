import Foundation
import ListenerCore
import ListenerMac
import os

enum TerminalInput: Sendable {
    case event(SessionEvent)
    case eventsEnded
    case typed(String)
    case interrupt
    case ask(AnswerTier)
    case audioEnded
    /// Something capture or speech reported on its own.
    case notice(String)
}

extension SessionCallbacks {
    /// Sends capture events and on-device model progress to the terminal loop.
    static func terminal(_ continuation: AsyncStream<TerminalInput>.Continuation) -> SessionCallbacks {
        SessionCallbacks(
            captureEvent: { event in
                continuation.yield(.notice(event.description))
            },
            onDeviceSpeech: { status in
                switch status {
                case .checking:
                    break
                case .downloading:
                    continuation.yield(.notice("Downloading the on-device speech model for this language..."))
                case .ready(let locale):
                    Log.speech.info("On-device speech ready for \(locale, privacy: .public)")
                    continuation.yield(.notice("On-device speech is ready (\(locale))."))
                case .failed(let message):
                    Log.speech.error("On-device speech unavailable: \(message, privacy: .public)")
                    continuation.yield(.notice(message))
                }
            }
        )
    }
}

/// Runs a CallSession in the terminal. Session events, typed commands, Ctrl-C and
/// replay triggers all arrive through one loop, which is the only thing that
/// writes to the terminal, so the live line and streaming answers never collide.
struct TerminalSession {
    static let keyHint = "Enter: quick answer.  d + Enter: deep answer.  Ctrl-C: stop and save.\n\n"

    let session: CallSession
    let style: TerminalStyle
    /// Live calls take commands from the keyboard; replays don't.
    let acceptsTyping: Bool

    /// Returns once the session has stopped and saved, with every answer it gave.
    func run(extraInputs: [AsyncStream<TerminalInput>] = []) async -> [AnswerRecord] {
        let (inputs, continuation) = AsyncStream.makeStream(of: TerminalInput.self)
        let session = session
        let interrupts = InterruptSignal()

        var feeds = [
            Task {
                for await event in session.events {
                    continuation.yield(.event(event))
                }
                continuation.yield(.eventsEnded)
            },
            Task {
                for await _ in interrupts.events {
                    continuation.yield(.interrupt)
                }
            },
        ]
        if acceptsTyping {
            feeds.append(
                Task {
                    for await line in Console.typedLines() {
                        continuation.yield(.typed(line))
                    }
                })
        }
        for stream in extraInputs {
            feeds.append(
                Task {
                    for await input in stream {
                        continuation.yield(input)
                    }
                })
        }

        var renderer = TerminalRenderer(style: style)
        var answers = AnswerLog()
        var eventLog = SessionEventLog()
        var stopping = false
        var lastNotice: String?
        let started = ContinuousClock.now

        func stopOnce() {
            if !stopping {
                stopping = true
                Task {
                    await session.stop()
                }
            }
        }

        loop: for await input in inputs {
            switch input {
            case .event(let event):
                eventLog.record(event)
                answers.apply(event, now: seconds(since: started))
                Console.write(renderer.render(event))
            case .eventsEnded:
                break loop
            case .typed(let line):
                Console.write(renderer.inputEchoed())
                switch line.trimmingCharacters(in: .whitespaces).lowercased() {
                case "":
                    if !stopping {
                        Task { await session.requestAnswer(.quick) }
                    }
                case "d", "deep":
                    if !stopping {
                        Task { await session.requestAnswer(.deep) }
                    }
                case "q", "quit", "stop":
                    stopOnce()
                default:
                    Console.write(renderer.clearLiveLine() + Self.keyHint)
                }
            case .ask(let tier):
                if !stopping {
                    Task { await session.requestAnswer(tier) }
                }
            case .interrupt:
                if stopping {
                    Console.write(renderer.clearLiveLine() + "\nQuit without waiting for the save.\n")
                    exit(130)
                }
                Console.write(renderer.clearLiveLine() + "\nStopping and saving. Press Ctrl-C again to quit at once.\n")
                stopOnce()
            case .notice(let message):
                if message != lastNotice {
                    lastNotice = message
                    Console.write(renderer.note(message))
                }
            case .audioEnded:
                if !stopping {
                    Console.write(renderer.clearLiveLine() + "\nEnd of the recordings. Stopping and saving.\n")
                    stopOnce()
                }
            }
        }

        Console.write(renderer.clearLiveLine())
        for feed in feeds {
            feed.cancel()
        }
        return answers.records
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
