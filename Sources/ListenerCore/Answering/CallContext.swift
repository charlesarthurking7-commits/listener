/// What kind of call this is and the background for it: the call type's instructions
/// and the documents the user added, such as a CV, a job description or a brief. It
/// goes into the system prompt of every answer and recap, and into the summary.
public struct CallContext: Sendable, Codable, Equatable {
    public struct Document: Sendable, Codable, Equatable {
        public var name: String
        public var text: String
    }

    /// The call type's name, e.g. "Work call". Empty when none was chosen.
    public var callType = ""
    /// How answers should go on this kind of call, in the user's words.
    public var instructions = ""
    public var documents: [Document] = []

    public static let none = CallContext()
}
