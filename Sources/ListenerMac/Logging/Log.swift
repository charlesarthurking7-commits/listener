import os

/// Unified logging for the whole app. Read it with
/// `log stream --predicate 'subsystem == "local.listener"' --level info`.
///
/// Transcript text, answer text and keys are never logged. Device names and file
/// paths are logged as private, so macOS redacts them unless private data logging
/// is turned on.
public enum Log {
    public static let subsystem = "local.listener"

    /// Calls starting and stopping, their channels, warnings and saving.
    public static let session = Logger(subsystem: subsystem, category: "session")
    /// Each answer's latency, model, tokens and cost.
    public static let answers = Logger(subsystem: subsystem, category: "answers")
    /// Speech-to-text setup and the on-device model.
    public static let speech = Logger(subsystem: subsystem, category: "speech")
    /// Capture devices, restarts and failures.
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    /// The window, menu bar and hotkeys.
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
