import Foundation

/// Which CSV column fills each field of the target table, and how rows go in
/// (S-045, Sequel Pro's field mapper): INSERT, REPLACE, or UPDATE matching rows.
public struct CSVMapping: Sendable, Equatable {
    /// How columns are first lined up with fields.
    public enum Alignment: String, CaseIterable, Sendable, Identifiable {
        case fileOrder, reversed, matchingNames, custom
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .fileOrder: "File Order"
            case .reversed: "Reversed Order"
            case .matchingNames: "Matching Names"
            case .custom: "Custom Order"
            }
        }
    }

    public enum Method: String, CaseIterable, Sendable, Identifiable {
        case insert = "INSERT", replace = "REPLACE", update = "UPDATE"
        public var id: String { rawValue }
    }

    /// The table's fields, in order.
    public var fields: [String]
    /// The file's columns: its first line's names, or Column 1, Column 2…
    public var columns: [String]
    /// For each field, the column that fills it, or nil (not imported).
    public var sources: [Int?]
    public var method = Method.insert
    /// INSERT IGNORE: rows whose key is already there are skipped.
    public var ignoreDuplicates = false
    /// UPDATE: the fields whose values find the row to change.
    public var matchFields: Set<String> = []
    /// The target's engine: SQLite (S-071) says INSERT OR IGNORE and has no backslash escapes.
    public var engine: Engine

    public init(fields: [String], columns: [String], alignment: Alignment = .fileOrder, engine: Engine) {
        self.fields = fields
        self.columns = columns
        self.engine = engine
        sources = Self.align(alignment, columns: columns, fields: fields)
    }

    /// The fields that are imported, with their columns, in field order.
    public var pairs: [(field: String, column: Int)] {
        zip(fields, sources).compactMap { field, column in column.map { (field, $0) } }
    }

    // MARK: Alignment

    /// The column for each field. Matching Names ignores case, spaces,
    /// underscores and hyphens; Custom keeps nothing and is set by hand.
    public static func align(_ alignment: Alignment, columns: [String], fields: [String]) -> [Int?] {
        switch alignment {
        case .fileOrder:
            return fields.indices.map { $0 < columns.count ? $0 : nil }
        case .reversed:
            let count = min(columns.count, fields.count)
            return fields.indices.map { $0 < count ? columns.count - 1 - $0 : nil }
        case .matchingNames:
            let exact = columns.map { $0.lowercased() }
            let loose = columns.map(squeezed)
            return fields.map { field in
                exact.firstIndex(of: field.lowercased()) ?? loose.firstIndex(of: squeezed(field))
            }
        case .custom:
            return fields.map { _ in nil }
        }
    }

    private static func squeezed(_ name: String) -> String {
        String(name.lowercased().filter { !" _-".contains($0) })
    }

    /// The first line's names, or "Column 1"…, one per column of the widest record.
    public static func columnNames(header: CSVRow?, count: Int) -> [String] {
        (0..<count).map { index in
            if let header, index < header.count, let name = header[index]?.trimmingCharacters(in: .whitespaces),
               !name.isEmpty {
                return name
            }
            return "Column \(index + 1)"
        }
    }

    // MARK: Checks

    /// Why Import can't run yet, or nil.
    public var problem: String? {
        let imported = pairs.map(\.field)
        if imported.isEmpty { return "Choose a column for at least one field." }
        guard method == .update else { return nil }
        let matched = imported.filter(matchFields.contains)
        if matched.isEmpty { return "Check Match for at least one imported field, to find the rows to update." }
        if matched.count == imported.count { return "Import at least one field that isn’t a Match field, to have something to update." }
        return nil
    }

    // MARK: SQL

    /// "INSERT IGNORE INTO `db`.`t` (`a`, `b`) VALUES ", followed by `tuple`s.
    public func insertPrefix(table: String, database: String) -> String {
        let ignore = engine == .sqlite ? "INSERT OR IGNORE" : "INSERT IGNORE"
        let verb = method == .replace ? "REPLACE" : (ignoreDuplicates ? ignore : "INSERT")
        let names = pairs.map { SQLQuote.identifier($0.field) }.joined(separator: ", ")
        return "\(verb) INTO \(SQLQuote.qualified(database, table)) (\(names)) VALUES "
    }

    /// "('a', NULL)": a record's values for the imported fields. A record too
    /// short for a column gives NULL.
    public func tuple(_ row: CSVRow) -> String {
        "(" + pairs.map { Self.literal(row, $0.column, engine: engine) }.joined(separator: ", ") + ")"
    }

    /// UPDATE `db`.`t` SET `b` = 'x' WHERE `a` = '1', with Match fields in the WHERE.
    public func update(_ row: CSVRow, table: String, database: String) -> String {
        var sets: [String] = []
        var wheres: [String] = []
        for (field, column) in pairs {
            let name = SQLQuote.identifier(field)
            let value = Self.literal(row, column, engine: engine)
            if matchFields.contains(field) {
                wheres.append(value == "NULL" ? "\(name) IS NULL" : "\(name) = \(value)")
            } else {
                sets.append("\(name) = \(value)")
            }
        }
        return "UPDATE \(SQLQuote.qualified(database, table)) SET \(sets.joined(separator: ", ")) "
            + "WHERE \(wheres.joined(separator: " AND "))"
    }

    static func literal(_ row: CSVRow, _ column: Int, engine: Engine) -> String {
        guard column < row.count, let value = row[column] else { return "NULL" }
        return SQLQuote.literal(value, engine: engine)
    }

    // MARK: New table

    /// A type that fits every sample value: INT, BIGINT, DECIMAL, DATE,
    /// DATETIME, VARCHAR(255) or TEXT. NULLs don't count; none at all is VARCHAR.
    /// A SQLite file (S-071) has INTEGER, REAL and TEXT, dates as TEXT.
    public static func guessType(_ values: [String?], engine: Engine) -> String {
        if engine == .sqlite {
            switch guessType(values, engine: .mysql) {
            case "INT", "BIGINT": return "INTEGER"
            case let type where type.hasPrefix("DECIMAL"): return "REAL"
            default: return "TEXT"
            }
        }
        let texts = values.compactMap { $0 }.filter { !$0.isEmpty }
        guard !texts.isEmpty else { return "VARCHAR(255)" }
        if texts.allSatisfy({ $0.wholeMatch(of: /-?[0-9]{1,18}/) != nil }) {
            let fitsInt = texts.allSatisfy { Int64($0).map { $0 >= Int64(Int32.min) && $0 <= Int64(Int32.max) } ?? false }
            return fitsInt ? "INT" : "BIGINT"
        }
        if texts.allSatisfy({ $0.wholeMatch(of: /-?[0-9]{1,30}(\.[0-9]{1,30})?/) != nil }) {
            var whole = 1, scale = 0
            for text in texts {
                let digits = text.drop { $0 == "-" }.split(separator: ".", omittingEmptySubsequences: false)
                whole = max(whole, digits[0].count)
                if digits.count > 1 { scale = max(scale, digits[1].count) }
            }
            return "DECIMAL(\(min(65, whole + scale)),\(min(30, scale)))"
        }
        if texts.allSatisfy({ $0.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil }) { return "DATE" }
        if texts.allSatisfy({ $0.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,6})?)?/) != nil }) {
            return "DATETIME"
        }
        return texts.contains { $0.count > 255 } ? "TEXT" : "VARCHAR(255)"
    }

    /// CREATE TABLE for a new table with these fields, every one nullable
    /// (SQLite's are without saying so).
    public static func createTable(_ name: String, database: String, fields: [(name: String, type: String)],
                                   engine: Engine) -> String {
        let null = engine == .sqlite ? "" : " NULL"
        let definitions = fields.map { "\(SQLQuote.identifier($0.name)) \($0.type.trimmingCharacters(in: .whitespaces))" + null }
        return "CREATE TABLE \(SQLQuote.qualified(database, name)) (\(definitions.joined(separator: ", ")))"
    }
}
