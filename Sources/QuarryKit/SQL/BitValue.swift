import Foundation

/// A BIT(1)…BIT(64) value (S-013): its bits, its bytes as the server sends
/// them (big-endian), and the same number in hexadecimal, decimal and octal.
public struct BitValue: Sendable, Hashable {
    /// How many bits the field holds, 1…64.
    public let width: Int
    /// The value; bits above `width` are always zero.
    public private(set) var raw: UInt64

    public init(width: Int, raw: UInt64 = 0) {
        self.width = Self.clamp(width)
        self.raw = raw & Self.mask(self.width)
    }

    /// From the server's bytes, most significant first.
    public init(width: Int, data: Data) {
        self.init(width: width, raw: data.suffix(8).reduce(0) { $0 << 8 | UInt64($1) })
    }

    /// From a cell: bytes as the server sends them, or text such as "5",
    /// "b'101'" or "0x1F" (a new row's default). Anything else is zero.
    public init(width: Int, value: CellValue) {
        switch value {
        case .binary(let data): self.init(width: width, data: data)
        case .text(let text): self.init(width: width, raw: Self.parseLiteral(text) ?? 0)
        case .null, .flag: self.init(width: width)
        }
    }

    /// The width from SHOW COLUMNS' length ("8" in bit(8)); BIT alone is BIT(1).
    public static func width(fromLength length: String) -> Int {
        clamp(Int(length.trimmingCharacters(in: .whitespaces)) ?? 1)
    }

    /// The largest value the field holds.
    public var maximum: UInt64 { Self.mask(width) }

    // MARK: Forms

    /// The bytes to save: ceil(width / 8) of them, most significant first.
    public var data: Data {
        let count = (width + 7) / 8
        return Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: raw >> (UInt64($0) * 8)) })
    }

    /// "00000101": every bit, most significant first.
    public var bits: String {
        String((0..<width).reversed().map { bit($0) ? "1" : "0" })
    }

    public var hex: String { String(raw, radix: 16, uppercase: true) }
    public var decimal: String { String(raw) }
    public var octal: String { String(raw, radix: 8) }

    /// Reads typed text in one base. Spaces and underscores are ignored, as is
    /// a 0x, 0o or 0b prefix that matches the base. Nil when the text is not a
    /// number in that base or does not fit in `width` bits.
    public func parse(_ text: String, radix: Int) -> UInt64? {
        var digits = text.filter { !$0.isWhitespace && $0 != "_" }.lowercased()
        let prefix = [16: "0x", 8: "0o", 2: "0b"][radix]
        if let prefix, digits.hasPrefix(prefix) { digits.removeFirst(2) }
        guard !digits.isEmpty, let value = UInt64(digits, radix: radix), value <= maximum else { return nil }
        return value
    }

    // MARK: Changes

    public func bit(_ index: Int) -> Bool {
        index >= 0 && index < width && raw >> UInt64(index) & 1 == 1
    }

    public mutating func set(_ value: UInt64) { raw = value & maximum }

    public mutating func toggle(_ index: Int) {
        guard index >= 0, index < width else { return }
        raw ^= 1 << UInt64(index)
    }

    public mutating func setAll() { raw = maximum }
    public mutating func clearAll() { raw = 0 }
    public mutating func invert() { raw = ~raw & maximum }

    /// Moves every bit up one; the top bit falls off and bit 0 becomes 0.
    public mutating func shiftLeft() { raw = raw << 1 & maximum }
    /// Moves every bit down one; bit 0 falls off and the top bit becomes 0.
    public mutating func shiftRight() { raw >>= 1 }
    /// Moves every bit up one; the top bit comes back in as bit 0.
    public mutating func rotateLeft() {
        let top = raw >> UInt64(width - 1) & 1
        raw = (raw << 1 | top) & maximum
    }
    /// Moves every bit down one; bit 0 comes back in as the top bit.
    public mutating func rotateRight() {
        let low = raw & 1
        raw = raw >> 1 | low << UInt64(width - 1)
    }

    // MARK: Helpers

    private static func clamp(_ width: Int) -> Int { min(max(width, 1), 64) }

    private static func mask(_ width: Int) -> UInt64 { width >= 64 ? .max : (1 << UInt64(width)) - 1 }

    /// "5", "b'101'", "0b101", "x'1F'", "0x1F".
    static func parseLiteral(_ text: String) -> UInt64? {
        let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
        func quoted(_ letter: String) -> String? {
            guard lower.hasPrefix(letter + "'"), lower.hasSuffix("'"), lower.count >= 3 else { return nil }
            return String(lower.dropFirst(2).dropLast())
        }
        if let digits = quoted("b") { return UInt64(digits, radix: 2) }
        if let digits = quoted("x") { return UInt64(digits, radix: 16) }
        if lower.hasPrefix("0b") { return UInt64(lower.dropFirst(2), radix: 2) }
        if lower.hasPrefix("0x") { return UInt64(lower.dropFirst(2), radix: 16) }
        return UInt64(lower)
    }
}
