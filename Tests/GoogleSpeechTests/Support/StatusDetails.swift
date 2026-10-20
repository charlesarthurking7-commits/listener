import Foundation

/// `grpc-status-details-bin` payloads (a serialized google.rpc.Status), written out by
/// hand because the test target has no protobuf runtime of its own.
enum StatusDetails {
    /// What Google returns when the Speech-to-Text API is off in the project.
    static let serviceDisabled = status(
        code: 7,
        message: "Cloud Speech-to-Text API has not been used in project 123 before or it is disabled.",
        reason: "SERVICE_DISABLED",
        metadata: [
            "activationUrl":
                "https://console.developers.google.com/apis/api/speech.googleapis.com/overview?project=123",
            "consumer": "projects/123",
            "service": "speech.googleapis.com",
        ])

    static func status(code: Int, message: String, reason: String, metadata: [String: String]) -> [UInt8] {
        let entries = metadata.sorted { $0.key < $1.key }.flatMap { key, value in
            bytes(3, bytes(1, key) + bytes(2, value))
        }
        let errorInfo = bytes(1, reason) + bytes(2, "googleapis.com") + entries
        let any = bytes(1, "type.googleapis.com/google.rpc.ErrorInfo") + bytes(2, errorInfo)
        return [0x08] + varint(code) + bytes(2, message) + bytes(3, any)
    }

    private static func bytes(_ field: Int, _ text: String) -> [UInt8] {
        bytes(field, Array(text.utf8))
    }

    /// A length-delimited field.
    private static func bytes(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        varint(field << 3 | 2) + varint(payload.count) + payload
    }

    private static func varint(_ value: Int) -> [UInt8] {
        var value = value
        var result: [UInt8] = []
        while value >= 0x80 {
            result.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        return result + [UInt8(value)]
    }
}
