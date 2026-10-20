/// A streaming speech-to-text service. One stream per channel, so "Me" and "Them"
/// are recognised independently and never get mixed up.
public protocol SpeechToTextProvider: Sendable {
    /// Short name for logs and the UI, e.g. "Google chirp_3 (eu)".
    var displayName: String { get }

    func openStream(for speaker: Speaker) async throws -> any SpeechStream
}

public protocol SpeechStream: AnyObject, Sendable {
    /// Recognition results in the order the provider produced them. Ends after
    /// `finish()` once the last final has arrived, or with an error.
    var events: AsyncThrowingStream<SpeechEvent, any Error> { get }

    /// Sends 16 kHz mono audio. Providers that limit stream length (Google: five
    /// minutes) reconnect behind this call; the caller never sees it.
    func send(_ chunk: AudioChunk) async throws

    /// Flushes buffered audio and closes the stream.
    func finish() async
}

public struct SpeechEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A guess that may still change. Each interim replaces the previous one.
        case interim
        /// Settled text. The next interim starts a new utterance.
        case final
    }

    public var kind: Kind
    public var text: String
    /// Seconds of this channel's audio since its first chunk, when the provider
    /// reports them. Providers that reconnect add the earlier streams' duration.
    public var audioStart: Double?
    public var audioEnd: Double?

    public init(kind: Kind, text: String, audioStart: Double? = nil, audioEnd: Double? = nil) {
        self.kind = kind
        self.text = text
        self.audioStart = audioStart
        self.audioEnd = audioEnd
    }
}
