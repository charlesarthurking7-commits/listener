import Foundation

/// One speaker's turn: consecutive final results from the same channel with no long
/// pause and nobody else talking in between. Times are seconds since the session started.
public struct Turn: Sendable, Codable, Equatable, Identifiable {
    public let id: Int
    public let speaker: Speaker
    public var text: String
    public var start: Double
    public var end: Double

    public init(id: Int, speaker: Speaker, text: String, start: Double, end: Double) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
    }
}

/// What the UI and the prompt builder see: settled turns plus whatever each speaker
/// is saying right now that has not been finalised yet.
public struct TranscriptSnapshot: Sendable, Equatable {
    public var turns: [Turn]
    public var interim: [Speaker: String]

    public init(turns: [Turn] = [], interim: [Speaker: String] = [:]) {
        self.turns = turns
        self.interim = interim
    }
}

/// The scripted conversation behind a fixture recording. Replay tests and the fake
/// speech-to-text provider use it as ground truth.
public struct ConversationScript: Sendable, Codable, Equatable {
    public struct Line: Sendable, Codable, Equatable {
        public var speaker: Speaker
        /// Seconds from the start of the recording.
        public var start: Double
        public var end: Double
        public var text: String

        public init(speaker: Speaker, start: Double, end: Double, text: String) {
            self.speaker = speaker
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public var title: String
    public var lines: [Line]

    public init(title: String, lines: [Line]) {
        self.title = title
        self.lines = lines
    }

    public static func load(from url: URL) throws -> ConversationScript {
        try JSONDecoder().decode(ConversationScript.self, from: Data(contentsOf: url))
    }
}
