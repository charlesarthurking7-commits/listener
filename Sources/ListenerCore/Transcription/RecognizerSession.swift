/// A recognizer that works in sessions, each of which can be ended at any moment to
/// settle everything it has heard, like Apple's SpeechAnalyzer. `RotatingSpeechStream`
/// turns one into a `SpeechStream`.
public protocol SessionRecognizer: Sendable {
    /// Starts a session. Its time zero is the first sample sent to it.
    func startSession() async throws -> any RecognizerSession
}

public protocol RecognizerSession: AnyObject, Sendable {
    /// Results in order. Ends once the session has finished or been cancelled, and
    /// throws if the recognizer fails.
    var results: AsyncThrowingStream<RecognizerResult, any Error> { get }

    /// 16 kHz mono audio. Called from one task at a time, in order.
    func send(_ samples: [Int16]) throws

    /// Ends the input and settles everything sent so far. `results` ends after the last
    /// final result.
    func finish() async

    /// Stops at once without settling anything more. `results` ends.
    func cancel() async
}
