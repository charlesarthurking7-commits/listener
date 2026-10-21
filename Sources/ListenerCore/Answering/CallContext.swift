/// What kind of call this is and the background for it: the call type's instructions
/// and the documents the user added, such as a CV, a job description or a brief. It
/// goes into the system prompt of every answer and recap, and into the summary.
public struct CallContext: Sendable, Codable, Equatable {
    public struct Document: Sendable, Codable, Equatable {
        public var name: String
        public var text: String

        public init(name: String, text: String) {
            self.name = name
            self.text = text
        }
    }

    /// The call type's name, e.g. "Work call". Empty when none was chosen.
    public var callType: String
    /// How answers should go on this kind of call, in the user's words.
    public var instructions: String
    public var documents: [Document]

    public init(callType: String = "", instructions: String = "", documents: [Document] = []) {
        self.callType = callType
        self.instructions = instructions
        self.documents = documents
    }

    public static let none = CallContext()
}
