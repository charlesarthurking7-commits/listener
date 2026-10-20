import Foundation

/// Parses .env files: one KEY=VALUE per line.
///
/// - Blank lines and lines starting with # are skipped, as is an `export ` prefix.
/// - Unquoted values end at " #", so a trailing comment is not part of the value.
/// - 'single quotes' keep everything literally.
/// - "double quotes" understand \n, \t, \" and \\.
/// - Lines that don't parse are skipped. A later line wins over an earlier one.
public enum DotEnv {
    public static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            if let (key, value) = parseLine(Substring(line)) {
                values[key] = value
            }
        }
        return values
    }

    static func parseLine(_ line: Substring) -> (String, String)? {
        var rest = line.drop(while: \.isWhitespace)
        if rest.isEmpty || rest.first == "#" {
            return nil
        }
        if rest.hasPrefix("export "), rest.contains("=") {
            rest = rest.dropFirst("export ".count).drop(while: \.isWhitespace)
        }
        guard let equals = rest.firstIndex(of: "=") else {
            return nil
        }
        let key = rest[..<equals].trimmingCharacters(in: .whitespaces)
        guard isValidKey(key), let value = parseValue(rest[rest.index(after: equals)...].drop(while: \.isWhitespace))
        else {
            return nil
        }
        return (key, value)
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, !isDigit(first) else {
            return false
        }
        return key.unicodeScalars.allSatisfy { $0 == "_" || $0 == "." || isLetter($0) || isDigit($0) }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    private static func parseValue(_ raw: Substring) -> String? {
        switch raw.first {
        case "'":
            let body = raw.dropFirst()
            guard let close = body.firstIndex(of: "'") else {
                return nil
            }
            return String(body[..<close])
        case "\"":
            return parseDoubleQuoted(raw.dropFirst())
        default:
            var value = raw
            if let comment = value.firstRange(of: " #") ?? value.firstRange(of: "\t#") {
                value = value[..<comment.lowerBound]
            }
            return value.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func parseDoubleQuoted(_ body: Substring) -> String? {
        var result = ""
        var escaping = false
        for character in body {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
        }
        return nil
    }
}
