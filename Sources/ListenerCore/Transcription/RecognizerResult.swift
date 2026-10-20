/// One result from an on-device recognizer that first reports "volatile" guesses and
/// later settles them into final text, the way Apple's SpeechTranscriber does. Plain
/// values, so the logic that turns these into `SpeechEvent`s builds and tests on Linux.
///
/// Times are seconds from the start of the recognizer session, nil when the recognizer
/// did not report them.
public struct RecognizerResult: Sendable, Equatable {
    /// A slice of the text with the audio it was heard in. Slices concatenate to the
    /// full text, spaces and punctuation included.
    public struct Piece: Sendable, Equatable {
        public var text: String
        public var start: Double?
        public var end: Double?

        public init(text: String, start: Double? = nil, end: Double? = nil) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    public var isFinal: Bool
    public var start: Double?
    public var end: Double?
    /// The recognizer will not change anything before this time any more, whether or
    /// not it sends a final result for it.
    public var finalizedThrough: Double?
    public var pieces: [Piece]

    public init(
        isFinal: Bool, start: Double?, end: Double?, finalizedThrough: Double? = nil, pieces: [Piece]
    ) {
        self.isFinal = isFinal
        self.start = start
        self.end = end
        self.finalizedThrough = finalizedThrough
        self.pieces = pieces
    }

    public var text: String {
        pieces.map(\.text).joined()
    }
}
