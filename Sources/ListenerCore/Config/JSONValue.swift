import Foundation

/// A parsed JSON document. The settings loader works on this tree so it can merge a
/// partial settings file over the defaults and point at the exact key that is wrong.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(parsing data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public init<Value: Encodable>(encoding value: Value) throws {
        self = try JSONValue(parsing: JSONEncoder().encode(value))
    }

    public func data() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self {
            return object
        }
        return nil
    }

    /// The value at a dotted path such as "storage.retentionDays", if there is one.
    public func value(at path: [String]) -> JSONValue? {
        var current = self
        for key in path {
            guard let next = current.objectValue?[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    /// `other` laid over `self`: objects merge key by key at every depth, anything
    /// else in `other` replaces what was there.
    public func merging(_ other: JSONValue) -> JSONValue {
        guard case .object(var base) = self, case .object(let overlay) = other else {
            return other
        }
        for (key, value) in overlay {
            base[key] = base[key].map { $0.merging(value) } ?? value
        }
        return .object(base)
    }

    /// A short rendering for error messages, e.g. `"thirty"` or `[1, 2]`.
    public var preview: String {
        switch self {
        case .null: "null"
        case .bool(let value): String(value)
        case .integer(let value): String(value)
        case .number(let value): String(value)
        case .string(let value): "\"\(value)\""
        case .array: "a list"
        case .object: "an object"
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
