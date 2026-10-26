import Foundation

/// One speaker's turn: consecutive final results from the same channel with no long
/// pause and nobody else talking in between. Times are seconds since the session started.
public struct Turn: Sendable, Codable, Equatable, Identifiable {
    public let id: Int
    public let speaker: Speaker
    public var text: String
    public var start: Double
    public var end: Double
}

/// What the UI and the prompt builder see: settled turns plus whatever each speaker
/// is saying right now that has not been finalised yet.
public struct TranscriptSnapshot: Sendable, Equatable {
    public var turns: [Turn] = []
    public var interim: [Speaker: String] = [:]
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
    }

    public var title: String
    public var lines: [Line]

    public static func load(from url: URL) throws -> ConversationScript {
        try JSONDecoder().decode(ConversationScript.self, from: Data(contentsOf: url))
    }
}
