import Foundation

/// Which cells of a query result can be edited, and the SQL that edits them (S-035).
///
/// As in Sequel Pro, a column is editable when the server says which table
/// and column it came from, and every primary-key column of that table is in
/// the result too, so the row can be found again. A JOIN is editable table by
/// table; computed columns, and tables with no primary key or missing key
/// columns, stay read-only and say why.
public struct ResultEditing: Sendable, Equatable {
    /// A table a result column came from.
    public struct Source: Sendable, Hashable {
        public var database: String
        public var table: String
        public init(database: String, table: String) {
            self.database = database
            self.table = table
        }
    }

    public enum Access: Sendable, Equatable {
        case editable(Source)
        case readOnly(String)
    }

    public let columns: [ResultColumn]
    /// How values are quoted in the edits (SQLite has no backslash escapes).
    public let engine: Engine
    /// One per column.
    public let access: [Access]
    /// Each editable table's primary-key columns, as result column indexes.
    private let keys: [Source: [Int]]

    /// The tables to look up: every (database, table) a column names.
    public static func sources(of columns: [ResultColumn]) -> [Source] {
        var seen = Set<Source>()
        return columns.compactMap { column in
            guard let source = source(of: column), seen.insert(source).inserted else { return nil }
            return source
        }
    }

    /// `primaryKeys` holds each source's primary-key column names (empty for
    /// none); a source missing from it could not be looked up.
    public init(columns: [ResultColumn], primaryKeys: [Source: [String]], engine: Engine) {
        self.columns = columns
        self.engine = engine
        var keys: [Source: [Int]] = [:]
        var reasons: [Source: String] = [:]
        for source in Self.sources(of: columns) {
            guard let names = primaryKeys[source] else {
                reasons[source] = "Read-only: \(source.table) is not a table that can be edited."
                continue
            }
            guard !names.isEmpty else {
                reasons[source] = "Read-only: \(source.table) has no primary key, so its rows can't be found to save a change."
                continue
            }
            var indexes: [Int] = []
            var missing: [String] = []
            for name in names {
                if let index = columns.indices.first(where: {
                    Self.source(of: columns[$0]) == source && columns[$0].orgName.caseInsensitiveCompare(name) == .orderedSame
                }) {
                    indexes.append(index)
                } else {
                    missing.append(name)
                }
            }
            if missing.isEmpty {
                keys[source] = indexes
            } else {
                let list = missing.joined(separator: ", ")
                reasons[source] = "Read-only: add \(list) (the primary key of \(source.table)) to the SELECT to edit this column."
            }
        }
        self.keys = keys
        access = columns.map { column in
            guard let source = Self.source(of: column) else {
                return .readOnly("Read-only: computed by the query, not stored in a table.")
            }
            return keys[source] != nil ? .editable(source) : .readOnly(reasons[source] ?? "Read-only.")
        }
    }

    /// Nothing editable, so no SQL is ever built and the engine is only a placeholder.
    public static let none = ResultEditing(columns: [], primaryKeys: [:], engine: .mysql)

    public var hasEditableColumns: Bool { access.contains { if case .editable = $0 { true } else { false } } }

    public func source(column: Int) -> Source? {
        guard column < access.count, case .editable(let source) = access[column] else { return nil }
        return source
    }

    /// Why a column is read-only; nil when it is editable.
    public func reason(column: Int) -> String? {
        guard column < access.count else { return nil }
        if case .readOnly(let reason) = access[column] { return reason }
        return nil
    }

    /// `UPDATE db.table SET col = value WHERE pk = …` for one cell, or nil when it is read-only.
    public func updateSQL(row: [CellValue], column: Int, value: CellValue) -> String? {
        guard let source = source(column: column), let key = keys[source] else { return nil }
        let (table, values) = projection(source, key: key, row: row)
        guard let index = table.firstIndex(where: { $0.name.caseInsensitiveCompare(columns[column].orgName) == .orderedSame })
        else { return nil }
        return RowEdit.updateSQL(database: source.database, table: source.table, columns: table, row: values,
                                 changes: [index: value], engine: engine)
    }

    /// `SELECT col, … FROM db.table WHERE pk = … LIMIT 1`: the source's columns
    /// of `row` as the server now stores them. The values come back in the
    /// order of `refetchColumns(source:)`.
    public func refetchSQL(source: Source, row: [CellValue]) -> String? {
        guard let key = keys[source] else { return nil }
        let (table, values) = projection(source, key: key, row: row)
        let names = table.map { SQLQuote.identifier($0.name) }.joined(separator: ", ")
        return "SELECT " + names + " FROM " + SQLQuote.qualified(source.database, source.table)
            + " WHERE " + RowEdit.whereClause(columns: table, row: values, engine: engine) + " LIMIT 1"
    }

    /// For each value `refetchSQL` returns, the result columns that show it
    /// (a column selected twice shows in both).
    public func refetchColumns(source: Source) -> [[Int]] {
        var order: [String] = []
        var map: [String: [Int]] = [:]
        for index in columns.indices where Self.source(of: columns[index]) == source {
            let name = columns[index].orgName.lowercased()
            if map[name] == nil { order.append(name) }
            map[name, default: []].append(index)
        }
        return order.map { map[$0]! }
    }

    /// True when `other` is the same row of `source` as `row`: equal primary-key values.
    public func sameRow(_ row: [CellValue], _ other: [CellValue], source: Source) -> Bool {
        guard let key = keys[source] else { return false }
        return key.allSatisfy { $0 < row.count && $0 < other.count && row[$0] == other[$0] }
    }

    /// The row with `value` at `column` and every other column that shows the same field.
    public func applying(_ value: CellValue, column: Int, to row: [CellValue]) -> [CellValue] {
        guard let source = source(column: column) else { return row }
        var row = row
        let name = columns[column].orgName.lowercased()
        for index in columns.indices where index < row.count && Self.source(of: columns[index]) == source
            && columns[index].orgName.lowercased() == name {
            row[index] = value
        }
        return row
    }

    /// The source's columns (named as in the table, deduplicated, key flagged) and their values in `row`.
    private func projection(_ source: Source, key: [Int], row: [CellValue]) -> ([ResultColumn], [CellValue]) {
        var table: [ResultColumn] = []
        var values: [CellValue] = []
        for group in refetchColumns(source: source) {
            let index = group[0]
            table.append(ResultColumn(name: columns[index].orgName, isPrimaryKey: group.contains { key.contains($0) }))
            values.append(index < row.count ? row[index] : .null)
        }
        return (table, values)
    }

    private static func source(of column: ResultColumn) -> Source? {
        guard !column.table.isEmpty, !column.database.isEmpty, !column.orgName.isEmpty else { return nil }
        return Source(database: column.database, table: column.table)
    }
}
