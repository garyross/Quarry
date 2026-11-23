import Foundation

/// Text for the Copy commands on a grid's selected rows (S-010).
public enum RowCopy {
    /// Tab-separated values, one row per line, NULL written as "NULL".
    /// With `names`, the first line holds the column names.
    public static func tabSeparated(columns: [String], rows: [[CellValue]], names: Bool) -> String {
        var lines = rows.map { row in row.map(text).joined(separator: "\t") }
        if names { lines.insert(columns.joined(separator: "\t"), at: 0) }
        return lines.joined(separator: "\n")
    }

    /// One INSERT for all rows, as Sequel Pro's Copy as SQL INSERT:
    /// INSERT INTO `t` (`a`, `b`)\nVALUES\n\t(1, 'x'),\n\t(2, NULL);
    /// Values are quoted as `engine` reads them, so the copy pastes back into the same kind of connection.
    public static func insertStatement(table: String, columns: [String], rows: [[CellValue]], engine: Engine) -> String {
        let names = columns.map(SQLQuote.identifier).joined(separator: ", ")
        let values = rows.map { "\t(" + $0.map { RowEdit.literal($0, engine: engine) }.joined(separator: ", ") + ")" }
        return "INSERT INTO " + SQLQuote.identifier(table) + " (" + names + ")\nVALUES\n" + values.joined(separator: ",\n") + ";"
    }

    /// The table a query result's Copy as SQL INSERT names: the one table every
    /// column came from, or Sequel Pro's `<table>` placeholder for a join or
    /// expressions, for people to fill in.
    public static func insertTable(for columns: [ResultColumn]) -> String {
        let tables = Set(columns.map(\.table))
        if tables.count == 1, let table = tables.first, !table.isEmpty { return table }
        return "<table>"
    }

    private static func text(_ value: CellValue) -> String {
        switch value {
        case .null: "NULL"
        case .text(let text): text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        case .binary(let data): "0x" + data.map { String(format: "%02X", $0) }.joined()
        case .flag(let on): on ? "1" : "0"
        }
    }
}

/// What a new row starts with, from SHOW FULL COLUMNS (S-010).
public enum NewRow {
    /// The value a new row shows before people change it: the literal default,
    /// the default's expression (current_timestamp()), NULL for a nullable
    /// column with no default or an auto_increment column, or empty text.
    public static func initialValue(_ field: FieldInfo) -> CellValue {
        if isAutoIncrement(field) || isGenerated(field) { return .null }
        if let value = field.defaultValue, !(field.isNullable && value == "NULL") { return .text(value) }
        return field.isNullable ? .null : .text("")
    }

    /// MySQL's auto_increment, or SQLite's INTEGER PRIMARY KEY (its rowid, "rowid" or "autoincrement").
    public static func isAutoIncrement(_ field: FieldInfo) -> Bool {
        field.extra.localizedCaseInsensitiveContains("auto_increment")
            || ["autoincrement", "rowid"].contains(field.extra.lowercased())
    }

    /// VIRTUAL or STORED GENERATED columns cannot take a value.
    public static func isGenerated(_ field: FieldInfo) -> Bool {
        field.extra.localizedCaseInsensitiveContains("generated")
    }

    /// The columns a duplicate copies: all but auto_increment and generated ones.
    public static func copiesValue(_ field: FieldInfo) -> Bool {
        !isAutoIncrement(field) && !isGenerated(field)
    }
}
