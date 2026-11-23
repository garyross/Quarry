import Foundation

/// An export's file name pattern (S-043), Sequel Pro's: text with tokens in
/// braces, such as `{database}_{date}`, expanded when the export starts.
/// Unknown braces stay as typed; colons and slashes become hyphens.
public struct ExportFileName: Sendable, Hashable {
    public enum Token: String, CaseIterable, Sendable, Identifiable {
        case database, table, host, connection, date, year, month, day, time, time24 = "24-hour-time"

        public var id: String { rawValue }
        /// The menu item's name.
        public var title: String {
            switch self {
            case .database: "Database"
            case .table: "Table"
            case .host: "Host"
            case .connection: "Connection"
            case .date: "Date"
            case .year: "Year"
            case .month: "Month"
            case .day: "Day"
            case .time: "Time"
            case .time24: "24-Hour Time"
            }
        }
        /// What the pattern holds: "{database}".
        public var text: String { "{" + rawValue + "}" }
    }

    /// What the tokens stand for in one export.
    public struct Values: Sendable {
        public var database: String
        public var table: String?
        public var host: String
        public var connection: String
        public var date: Date

        public init(database: String, table: String? = nil, host: String = "", connection: String = "", date: Date = .now) {
            self.database = database
            self.table = table
            self.host = host
            self.connection = connection
            self.date = date
        }
    }

    public var pattern: String

    public init(_ pattern: String) {
        self.pattern = pattern
    }

    /// No pattern: the export uses its default name.
    public var isEmpty: Bool { pattern.trimmingCharacters(in: .whitespaces).isEmpty }

    public func contains(_ token: Token) -> Bool { pattern.contains(token.text) }

    /// The tokens replaced, without an extension. Empty when the result is
    /// empty, so the caller falls back to its default name. `{table}` is empty
    /// when there is no table.
    public func expand(_ values: Values, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: values.date)
        parts.calendar = calendar
        func two(_ number: Int?) -> String { String(format: "%02d", number ?? 0) }
        var text = pattern
        for token in Token.allCases where text.contains(token.text) {
            let value: String = switch token {
            case .database: values.database
            case .table: values.table ?? ""
            case .host: values.host
            case .connection: values.connection
            case .date: "\(parts.year ?? 0)-\(two(parts.month))-\(two(parts.day))"
            case .year: String(parts.year ?? 0)
            case .month: two(parts.month)
            case .day: two(parts.day)
            case .time: Self.shortTime(values.date, calendar: calendar, locale: locale)
            case .time24: "\(two(parts.hour))-\(two(parts.minute))-\(two(parts.second))"
            }
            text = text.replacingOccurrences(of: token.text, with: value)
        }
        return Self.safe(text)
    }

    /// The name of each file when one export writes one file per table:
    /// the pattern with that table, or with "_table" added when the pattern
    /// has no `{table}`, so every file is different. An empty pattern gives
    /// the table's name.
    public func perTable(_ values: Values, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let table = values.table ?? ""
        guard !isEmpty else { return Self.safe(table) }
        let name = expand(values, calendar: calendar, locale: locale)
        if contains(.table) { return name.isEmpty ? Self.safe(table) : name }
        return name.isEmpty ? Self.safe(table) : name + "_" + Self.safe(table)
    }

    /// Colons and slashes become hyphens (Finder shows one as the other), and
    /// spaces at the ends go.
    public static func safe(_ text: String) -> String {
        text.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The locale's short time, "2.05 PM" or "14.05", with its colon made safe.
    private static func shortTime(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return safe(formatter.string(from: date)).replacingOccurrences(of: "\u{202F}", with: " ")
    }
}
