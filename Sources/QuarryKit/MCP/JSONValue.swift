import Foundation

/// A JSON value that can cross actors: MCP messages, tool arguments and
/// results (S-063). Encodes with sorted keys, so output is stable in tests.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Reading

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Whole numbers, also when a client sent them as 3.0 or "3".
    public var int: Int? {
        switch self {
        case .int(let value): value
        case .double(let value) where value.rounded() == value && abs(value) < 9e15: Int(value)
        case .string(let text): Int(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// true and false, also as "true"/"false" from clients that send strings.
    public var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .string(let text): ["true": true, "false": false][text.lowercased()]
        default: nil
        }
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }

    // MARK: Coding

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
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
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Parses one JSON document; nil when it is not JSON.
    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Compact JSON with sorted keys and unescaped slashes.
    public var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public var text: String { String(decoding: data, as: UTF8.self) }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue {
    /// A string, or null when there is none.
    public static func optional(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }
    /// A number, or null when there is none.
    public static func optional(_ number: Int?) -> JSONValue { number.map(JSONValue.int) ?? .null }
}
