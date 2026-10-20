/// Anything that produces one channel of audio: the mic, system audio, or a WAV file
/// being replayed.
public protocol AudioCaptureSource: AnyObject, Sendable {
    /// Starts capturing and calls `onChunk` from the source's own thread every time
    /// converted audio is ready. Returns what was opened, for logs and reports.
    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo
    func stop()
}
