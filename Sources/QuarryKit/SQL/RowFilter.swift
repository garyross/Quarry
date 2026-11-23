import Foundation

/// The quick filter above Content (S-014): one column, one operator, and up to
/// two values, turned into a WHERE clause.
///
/// Every value goes through `SQLQuote.literal(_:engine:)` and every name through
/// `SQLQuote.identifier`, so typed text can never end the clause. Operators
/// follow Sequel Pro's ContentFilters.plist, with names people read.
///
/// The one exception is a WHERE clause rule (S-061, `.sql`): its value is SQL
/// people type themselves, for what the operators can't say. It is wrapped in
/// parentheses, with a line break before the closing one so a trailing `--`
/// comment can't swallow the rest of the query.
public struct RowFilter: Sendable, Hashable, Codable {
    public enum Operator: String, CaseIterable, Sendable, Identifiable, Codable {
        case equals = "="
        case notEquals = "≠"
        case greater = ">"
        case less = "<"
        case greaterOrEqual = "≥"
        case lessOrEqual = "≤"
        case contains = "contains"
        case notContains = "does not contain"
        case startsWith = "starts with"
        case endsWith = "ends with"
        case like = "LIKE"
        case notLike = "NOT LIKE"
        case isIn = "IN"
        case between = "BETWEEN"
        case isNull = "IS NULL"
        case isNotNull = "IS NOT NULL"
        /// A condition typed as SQL (S-061); the rule's column is kept but not used.
        case sql = "WHERE clause"

        /// The operator menu: every operator but `.sql`, which the column menu offers.
        public static let comparisons = allCases.filter { $0 != .sql }

        public var id: String { rawValue }
        public var title: String { rawValue }

        /// How many values the operator takes: none, one, or two (BETWEEN).
        public var valueCount: Int {
            switch self {
            case .isNull, .isNotNull: 0
            case .between: 2
            default: 1
            }
        }

        /// Hover help for the value field.
        public var placeholder: String {
            switch self {
            case .isIn: "a, b, c"
            case .like, .notLike: "% any text, _ one character"
            case .between: "from"
            case .sql: "total > 100 AND status <> 'void'"
            default: "Value"
            }
        }

        /// Where the menu puts a divider before this operator.
        public var startsGroup: Bool { [.contains, .like, .isIn, .isNull].contains(self) }
    }

    public var column: String
    public var op: Operator
    public var value: String
    /// BETWEEN's upper bound.
    public var secondValue: String

    public init(column: String, op: Operator = .equals, value: String = "", secondValue: String = "") {
        self.column = column
        self.op = op
        self.value = value
        self.secondValue = secondValue
    }

    /// True when the rule has a column and the values its operator needs. A
    /// rule that is not set is left out of the filter, so an empty field
    /// filters nothing.
    public var isSet: Bool {
        if op == .sql { return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !column.isEmpty else { return false }
        switch op.valueCount {
        case 0: return true
        case 1: return op == .isIn ? !Self.listItems(value).isEmpty : !value.isEmpty
        default: return !value.trimmingCharacters(in: .whitespaces).isEmpty
            && !secondValue.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// True when the server can answer the rule from an index on its column:
    /// comparisons, ranges, lists and prefixes can; contains, ends with,
    /// negations and patterns read every row.
    public func canUseIndex(indexed: Set<String>) -> Bool {
        guard op != .sql, indexed.contains(column) else { return false }
        switch op {
        case .equals, .greater, .less, .greaterOrEqual, .lessOrEqual, .startsWith, .isIn, .between, .isNull: return true
        default: return false
        }
    }

    /// The condition without `WHERE`, or nil while the rule is not set, as MySQL reads it.
    public var whereClause: String? { whereClause(engine: .mysql) }

    /// The condition as `engine` reads it. SQLite (S-071) doubles quotes and
    /// has no backslash escapes, and its LIKE names its escape character.
    public func whereClause(engine: Engine) -> String? {
        guard isSet else { return nil }
        func quoted(_ text: String) -> String { SQLQuote.literal(text, engine: engine) }
        /// A pattern built with `likeEscaped`, whose backslashes escape.
        func pattern(_ text: String) -> String { quoted(text) + (engine == .sqlite ? " ESCAPE '\\'" : "") }
        if op == .sql { return "(" + value.trimmingCharacters(in: .whitespacesAndNewlines) + "\n)" }
        let name = SQLQuote.identifier(column)
        switch op {
        case .equals: return name + " = " + quoted(value)
        case .notEquals: return name + " != " + quoted(value)
        case .greater: return name + " > " + quoted(value)
        case .less: return name + " < " + quoted(value)
        case .greaterOrEqual: return name + " >= " + quoted(value)
        case .lessOrEqual: return name + " <= " + quoted(value)
        case .contains: return name + " LIKE " + pattern("%" + Self.likeEscaped(value) + "%")
        case .notContains: return name + " NOT LIKE " + pattern("%" + Self.likeEscaped(value) + "%")
        case .startsWith: return name + " LIKE " + pattern(Self.likeEscaped(value) + "%")
        case .endsWith: return name + " LIKE " + pattern("%" + Self.likeEscaped(value))
        case .like: return name + " LIKE " + quoted(value)
        case .notLike: return name + " NOT LIKE " + quoted(value)
        case .isIn:
            let items = Self.listItems(value)
            return name + " IN (" + items.map(quoted).joined(separator: ", ") + ")"
        case .between:
            let low = value.trimmingCharacters(in: .whitespaces)
            let high = secondValue.trimmingCharacters(in: .whitespaces)
            return name + " BETWEEN " + quoted(low) + " AND " + quoted(high)
        case .isNull: return name + " IS NULL"
        case .isNotNull: return name + " IS NOT NULL"
        case .sql: return nil
        }
    }

    /// Text matched literally inside a LIKE pattern: `%`, `_` and `\` lose their meaning.
    public static func likeEscaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if character == "\\" || character == "%" || character == "_" { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// IN's comma-separated values, trimmed; empty items are dropped.
    public static func listItems(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
