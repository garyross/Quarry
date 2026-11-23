import Foundation

/// How a CSV file is written, as the Export and Import sheets offer it
/// (S-042, S-045): Sequel Pro's separator, enclosure, escape and line-end
/// choices, field names in the first row, and NULL's text.
public struct CSVFormat: Sendable, Hashable {
    public enum Separator: String, CaseIterable, Identifiable, Sendable {
        case comma = ",", semicolon = ";", tab = "\t", pipe = "|"
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .comma: "Comma"
            case .semicolon: "Semicolon"
            case .tab: "Tab"
            case .pipe: "Vertical Bar"
            }
        }
    }

    public enum Enclosure: String, CaseIterable, Identifiable, Sendable {
        case double = "\"", single = "'", none = ""
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .double: "Double Quotes"
            case .single: "Single Quotes"
            case .none: "Nothing"
            }
        }
    }

    /// How a quote inside a value is written: doubled, or after a backslash.
    public enum Escape: String, CaseIterable, Identifiable, Sendable {
        case double = "\"", backslash = "\\"
        public var id: String { rawValue }
        public var title: String { self == .double ? "Doubling Them" : "Backslash" }
    }

    public enum LineEnd: String, CaseIterable, Identifiable, Sendable {
        case lf = "\n", crlf = "\r\n", cr = "\r"
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .lf: "LF (Mac, Linux)"
            case .crlf: "CRLF (Windows)"
            case .cr: "CR"
            }
        }
    }

    public var separator: Separator
    public var enclosure: Enclosure
    public var escape: Escape
    public var lineEnd: LineEnd
    public var header: Bool
    public var nullText: String

    public init(separator: Separator = .comma, enclosure: Enclosure = .double, escape: Escape = .double,
                lineEnd: LineEnd = .lf, header: Bool = true, nullText: String = "NULL") {
        self.separator = separator
        self.enclosure = enclosure
        self.escape = escape
        self.lineEnd = lineEnd
        self.header = header
        self.nullText = nullText
    }

    /// What the writer and the parser take. Doubling uses the enclosure itself.
    public var options: DataExport.CSVOptions {
        DataExport.CSVOptions(fieldSeparator: separator.rawValue, enclosure: enclosure.rawValue,
                              escape: escape == .double ? enclosure.rawValue : "\\",
                              lineEnd: lineEnd.rawValue, header: header, nullText: nullText)
    }
}
