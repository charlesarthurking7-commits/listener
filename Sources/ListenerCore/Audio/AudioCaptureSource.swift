/// Anything that produces one channel of audio: the mic, system audio, or a WAV file
/// being replayed.
public protocol AudioCaptureSource: AnyObject, Sendable {
    /// Starts capturing and calls `onChunk` from the source's own thread every time
    /// converted audio is ready. Returns what was opened, for logs and reports.
    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo
    func stop()
}

public struct ChannelInfo: Codable, Sendable, Equatable {
    public let speaker: Speaker
    public let backend: String
    public let device: String
    public let nativeFormat: String

    public init(speaker: Speaker, backend: String, device: String, nativeFormat: String) {
        self.speaker = speaker
        self.backend = backend
        self.device = device
        self.nativeFormat = nativeFormat
    }
}
