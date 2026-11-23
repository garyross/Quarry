import Foundation

/// Rules for the Field Editor (S-012): which values open in it, JSON
/// formatting and checking, and the Hex dump.
public enum LongValue {
    /// Field types whose values always open in the Field Editor. TEXT fields
    /// open it only for long values, so a short note still edits inline (and Set to NULL works).
    public static let longTypes: Set<String> = ["tinyblob", "blob", "mediumblob", "longblob", "json"]

    /// Longer values than this open in the Field Editor, not inline.
    public static let inlineLimit = 200

    /// True when the value opens in the Field Editor rather than inline:
    /// a BLOB or JSON field, bytes, a line break, a long value, or a JSON object or array.
    public static func opensFieldEditor(_ value: CellValue, fieldType: String?) -> Bool {
        if let fieldType, longTypes.contains(fieldType.lowercased()) { return true }
        switch value {
        case .binary: return true
        case .text(let text):
            return text.count > inlineLimit || text.contains(where: \.isNewline) || isJSONContainer(text)
        case .null, .flag: return false
        }
    }

    /// True when the value is edited as JSON: a JSON field, or text that is a JSON object or array.
    public static func isJSON(_ value: CellValue, fieldType: String?) -> Bool {
        if fieldType?.lowercased() == "json" { return true }
        guard case .text(let text) = value else { return false }
        return isJSONContainer(text)
    }

    static func isJSONContainer(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[" else { return false }
        return JSONText.check(text) == nil
    }
}

/// JSON as text: checked, pretty-printed and made compact without changing
/// key order or number spelling (JSONSerialization would do both).
public enum JSONText {
    /// Why text is not valid JSON, with where it went wrong (1-based).
    public struct Problem: Error, Equatable, Sendable {
        public var message: String
        public var line: Int
        public var column: Int

        /// "expected a value at line 3, column 5"
        public var description: String { "\(message) at line \(line), column \(column)" }
    }

    /// Nil when `text` is one valid JSON value (surrounding whitespace allowed).
    public static func check(_ text: String) -> Problem? {
        var parser = Parser(Array(text.utf8))
        do {
            parser.skipSpace()
            try parser.value(depth: 0)
            parser.skipSpace()
            if parser.index < parser.bytes.count { throw parser.problem("unexpected text after the value") }
            return nil
        } catch let problem as Problem {
            return problem
        } catch {
            return Problem(message: "not valid", line: 1, column: 1)
        }
    }

    /// Two-space indents, one member per line, `"key": value`. Invalid JSON comes back unchanged.
    public static func pretty(_ text: String) -> String {
        guard check(text) == nil else { return text }
        var out = ""
        var depth = 0
        let tokens = tokenize(text)
        func newline() { out += "\n" + String(repeating: "  ", count: depth) }
        for (index, token) in tokens.enumerated() {
            switch token {
            case "{", "[":
                out += token
                // An empty object or array stays on one line.
                if index + 1 < tokens.count, tokens[index + 1] == (token == "{" ? "}" : "]") { continue }
                depth += 1
                newline()
            case "}", "]":
                if index > 0, tokens[index - 1] == (token == "}" ? "{" : "[") {
                    out += token
                    continue
                }
                depth -= 1
                newline()
                out += token
            case ",":
                out += ","
                newline()
            case ":":
                out += ": "
            default:
                out += token
            }
        }
        return out
    }

    /// No whitespace outside strings. Invalid JSON comes back unchanged.
    public static func compact(_ text: String) -> String {
        guard check(text) == nil else { return text }
        return tokenize(text).joined()
    }

    /// True when the text has no whitespace outside strings.
    public static func isCompact(_ text: String) -> Bool {
        check(text) == nil && compact(text) == text
    }

    /// Strings (with their quotes and escapes), punctuation, and scalar runs.
    static func tokenize(_ text: String) -> [String] {
        let bytes = Array(text.utf8)
        var tokens: [String] = []
        var index = 0
        func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case UInt8(ascii: "\""):
                var end = index + 1
                while end < bytes.count, bytes[end] != UInt8(ascii: "\"") {
                    end += bytes[end] == UInt8(ascii: "\\") ? 2 : 1
                }
                end = min(end + 1, bytes.count)
                tokens.append(string(index..<end))
                index = end
            case UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "["), UInt8(ascii: "]"),
                 UInt8(ascii: ","), UInt8(ascii: ":"):
                tokens.append(string(index..<index + 1))
                index += 1
            default:
                var end = index
                while end < bytes.count, !"{}[],:\" \t\n\r".utf8.contains(bytes[end]) { end += 1 }
                tokens.append(string(index..<end))
                index = end
            }
        }
        return tokens
    }

    /// A recursive descent check of RFC 8259 JSON.
    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        func problem(_ message: String) -> Problem {
            var line = 1
            var column = 1
            for byte in bytes[..<min(index, bytes.count)] {
                if byte == 0x0A { line += 1; column = 1 } else if byte & 0xC0 != 0x80 { column += 1 }
            }
            return Problem(message: message, line: line, column: column)
        }

        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipSpace() {
            while let byte = current, [0x20, 0x09, 0x0A, 0x0D].contains(byte) { index += 1 }
        }

        mutating func expect(_ byte: Character, _ message: String) throws {
            guard current == byte.asciiValue else { throw problem(message) }
            index += 1
        }

        mutating func value(depth: Int) throws {
            guard depth < 512 else { throw problem("nested too deeply") }
            guard let byte = current else { throw problem("expected a value") }
            switch byte {
            case UInt8(ascii: "{"):
                index += 1
                skipSpace()
                if current == UInt8(ascii: "}") { index += 1; return }
                while true {
                    skipSpace()
                    guard current == UInt8(ascii: "\"") else { throw problem("expected a key in quotes") }
                    try string()
                    skipSpace()
                    try expect(":", "expected “:” after the key")
                    skipSpace()
                    try value(depth: depth + 1)
                    skipSpace()
                    if current == UInt8(ascii: ",") { index += 1; continue }
                    try expect("}", "expected “,” or “}”")
                    return
                }
            case UInt8(ascii: "["):
                index += 1
                skipSpace()
                if current == UInt8(ascii: "]") { index += 1; return }
                while true {
                    skipSpace()
                    try value(depth: depth + 1)
                    skipSpace()
                    if current == UInt8(ascii: ",") { index += 1; continue }
                    try expect("]", "expected “,” or “]”")
                    return
                }
            case UInt8(ascii: "\""):
                try string()
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                try number()
            default:
                for word in ["true", "false", "null"] where bytes[index...].starts(with: word.utf8) {
                    index += word.utf8.count
                    return
                }
                throw problem("expected a value")
            }
        }

        mutating func string() throws {
            index += 1
            while let byte = current {
                index += 1
                switch byte {
                case UInt8(ascii: "\""): return
                case UInt8(ascii: "\\"):
                    guard let escaped = current else { break }
                    index += 1
                    if escaped == UInt8(ascii: "u") {
                        for _ in 0..<4 {
                            guard let hex = current, (Character(UnicodeScalar(hex))).isHexDigit else {
                                throw problem("expected four hex digits after \\u")
                            }
                            index += 1
                        }
                    } else if !"\"\\/bfnrt".utf8.contains(escaped) {
                        index -= 1
                        throw problem("unknown escape")
                    }
                case 0..<0x20:
                    index -= 1
                    throw problem("control character in a string")
                default: break
                }
            }
            throw problem("unterminated string")
        }

        mutating func number() throws {
            func digits() -> Int {
                let start = index
                while let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
                return index - start
            }
            if current == UInt8(ascii: "-") { index += 1 }
            if current == UInt8(ascii: "0") {
                index += 1
            } else if digits() == 0 {
                throw problem("expected a digit")
            }
            if current == UInt8(ascii: ".") {
                index += 1
                if digits() == 0 { throw problem("expected a digit after “.”") }
            }
            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                index += 1
                if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
                if digits() == 0 { throw problem("expected a digit in the exponent") }
            }
        }
    }
}

/// The Field Editor's Hex mode: offset, 16 bytes, and their characters per line.
public enum HexDump {
    /// Dumps at most this many bytes; the rest is counted on a last line.
    public static let limit = 256 * 1024

    /// `00000000  89 50 4E 47 0D 0A 1A 0A  00 00 00 0D 49 48 44 52  |.PNG........IHDR|`
    public static func format(_ data: Data, limit: Int = HexDump.limit) -> String {
        let bytes = Array(data.prefix(limit))
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / 16 + 1)
        var start = 0
        while start < bytes.count {
            let chunk = bytes[start..<min(start + 16, bytes.count)]
            // Two groups of eight: 16 × 2 digits, 15 spaces, and one more between the groups.
            let pairs = chunk.map { String(format: "%02X", $0) }
            let hex = (pairs.prefix(8).joined(separator: " ") + (pairs.count > 8 ? "  " + pairs.dropFirst(8).joined(separator: " ") : ""))
                .padding(toLength: 48, withPad: " ", startingAt: 0)
            let chars = String(chunk.map { (0x20..<0x7F).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08X  ", start) + hex + "  |" + chars + "|")
            start += 16
        }
        if data.count > bytes.count {
            lines.append("… " + ByteCount.format(data.count - bytes.count) + " more")
        }
        return lines.joined(separator: "\n")
    }
}
