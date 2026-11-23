import Foundation

/// Database > View Using Encoding (S-056), as in Sequel Pro: the character
/// set the server sends text in (SET NAMES) and how Quarry reads the bytes.
/// "UTF-8 Unicode via Latin 1" fixes the common mix-up of UTF-8 text stored
/// in latin1 columns: the server sends the stored bytes unchanged and Quarry
/// reads them as UTF-8.
public enum ViewEncoding: String, CaseIterable, Sendable, Identifiable {
    case utf8mb4, utf8, utf8ViaLatin1 = "utf8-", ascii, latin1, macroman, cp1250, latin2, cp1256, greek, hebrew, latin5

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .utf8mb4: "UTF-8 Full Unicode (utf8mb4)"
        case .utf8: "UTF-8 Unicode BMP (utf8)"
        case .utf8ViaLatin1: "UTF-8 Unicode via Latin 1"
        case .ascii: "US ASCII (ascii)"
        case .latin1: "ISO Latin 1 (latin1)"
        case .macroman: "Mac Roman (macroman)"
        case .cp1250: "Windows Latin 2 (cp1250)"
        case .latin2: "ISO Latin 2 (latin2)"
        case .cp1256: "Windows Arabic (cp1256)"
        case .greek: "ISO Greek (greek)"
        case .hebrew: "ISO Hebrew (hebrew)"
        case .latin5: "ISO Turkish (latin5)"
        }
    }

    /// The name SET NAMES takes.
    public var charset: String { self == .utf8ViaLatin1 ? "latin1" : rawValue }

    /// Statements still go out as UTF-8 (MySQLNIO sends no other bytes), which the
    /// server reads correctly only in these modes; "via Latin 1" stores them as the
    /// mixed-up data it shows. Other modes refuse text that is not plain ASCII.
    public var sendsText: Bool { [.utf8mb4, .utf8, .utf8ViaLatin1].contains(self) }

    private var stringEncoding: String.Encoding {
        switch self {
        case .utf8mb4, .utf8, .utf8ViaLatin1: .utf8
        case .ascii: .ascii
        // MySQL's latin1 is Windows-1252.
        case .latin1: .windowsCP1252
        case .macroman: .macOSRoman
        case .cp1250: .windowsCP1250
        case .latin2: .isoLatin2
        case .cp1256: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsArabic.rawValue)))
        case .greek: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.isoLatinGreek.rawValue)))
        case .hebrew: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.isoLatinHebrew.rawValue)))
        case .latin5: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.isoLatin5.rawValue)))
        }
    }

    /// A text cell's bytes as text; nil when they are not valid in this encoding (the grid shows them as bytes).
    public func decode(_ bytes: [UInt8]) -> String? {
        if stringEncoding == .utf8 { return String(validating: bytes, as: UTF8.self) }
        return String(bytes: bytes, encoding: stringEncoding)
    }

    /// Why a statement can't be sent in this mode; nil when it can.
    public func problem(sending sql: String) -> String? {
        guard !sendsText, !sql.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return "Statements with characters beyond plain ASCII can’t be sent while viewing as \(title)."
    }
}
