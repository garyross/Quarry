import Foundation

/// SQL for adding, changing and deleting one row of a table that Content shows.
///
/// The row is found by its primary key. A table with no primary key is
/// matched on every column, with LIMIT 1 so at most one copy of a duplicate
/// row changes (as Sequel Pro did). SQLite (S-069) has no LIMIT on UPDATE or
/// DELETE: there a table with no primary key is found by its `rowid`, which
/// the caller passes as a primary-key column.
public enum RowEdit {
    /// `UPDATE db.table SET col = value, … WHERE … [LIMIT 1]`.
    /// `columns` and `row` are the row as loaded; `changes` maps column index to the new value.
    public static func updateSQL(database: String, table: String, columns: [ResultColumn],
                                 row: [CellValue], changes: [Int: CellValue], engine: Engine) -> String {
        let assignments = changes.keys.sorted().map { index in
            SQLQuote.identifier(columns[index].name) + " = " + literal(changes[index]!, engine: engine)
        }
        var sql = "UPDATE " + SQLQuote.qualified(database, table) + " SET " + assignments.joined(separator: ", ")
        sql += " WHERE " + whereClause(columns: columns, row: row, engine: engine)
        if !hasPrimaryKey(columns), engine == .mysql { sql += " LIMIT 1" }
        return sql
    }

    /// `INSERT INTO db.table (col, …) VALUES (…)`. With no columns, every
    /// value comes from the table's defaults: `INSERT INTO db.table () VALUES ()`,
    /// or SQLite's `INSERT INTO db.table DEFAULT VALUES`.
    public static func insertSQL(database: String, table: String, values: [(column: String, value: CellValue)],
                                 engine: Engine) -> String {
        if values.isEmpty, engine == .sqlite { return "INSERT INTO " + SQLQuote.qualified(database, table) + " DEFAULT VALUES" }
        let names = values.map { SQLQuote.identifier($0.column) }.joined(separator: ", ")
        let literals = values.map { literal($0.value, engine: engine) }.joined(separator: ", ")
        return "INSERT INTO " + SQLQuote.qualified(database, table) + " (" + names + ") VALUES (" + literals + ")"
    }

    /// `DELETE FROM db.table WHERE … LIMIT 1`: one row, found as `updateSQL` finds it.
    /// LIMIT 1 keeps a duplicate row in a table with no primary key from going too;
    /// SQLite's key (or rowid) is unique, so it has none.
    public static func deleteSQL(database: String, table: String, columns: [ResultColumn], row: [CellValue],
                                 engine: Engine) -> String {
        let sql = "DELETE FROM " + SQLQuote.qualified(database, table) + " WHERE " + whereClause(columns: columns, row: row, engine: engine)
        return engine == .mysql ? sql + " LIMIT 1" : sql
    }

    public static func hasPrimaryKey(_ columns: [ResultColumn]) -> Bool {
        columns.contains(where: \.isPrimaryKey)
    }

    /// `pk` = 1 AND …, or every column when there is no primary key. NULL matches with IS NULL.
    public static func whereClause(columns: [ResultColumn], row: [CellValue], engine: Engine) -> String {
        let key = hasPrimaryKey(columns) ? columns.indices.filter { columns[$0].isPrimaryKey } : Array(columns.indices)
        return key.map { index in
            let name = SQLQuote.identifier(columns[index].name)
            let value = index < row.count ? row[index] : .null
            return value.isNull ? name + " IS NULL" : name + " = " + literal(value, engine: engine)
        }.joined(separator: " AND ")
    }

    /// A value as SQL: NULL, 'text' (quoted as `engine` reads it), or X'hex' for bytes.
    public static func literal(_ value: CellValue, engine: Engine) -> String {
        switch value {
        case .null: "NULL"
        case .text(let text): SQLQuote.literal(text, engine: engine)
        case .binary(let data): "X'" + data.map { String(format: "%02X", $0) }.joined() + "'"
        case .flag(let on): on ? "1" : "0"
        }
    }
}
