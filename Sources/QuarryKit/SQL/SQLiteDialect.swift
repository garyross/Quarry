import Foundation

/// SQLite's SQL for the catalog and agents (S-068). A file has one database,
/// `main`; schema reads come from `sqlite_schema` and the PRAGMA table-valued
/// functions, and are shaped like MySQL's answers (SHOW INDEX, SHOW TRIGGERS,
/// SHOW TABLE STATUS) so the views read them the same way. SQLite accepts
/// backtick identifiers, so quoting stays `SQLQuote`'s.
public struct SQLiteDialect: SQLDialect {
    public init() {}

    public var engine: Engine { .sqlite }

    /// The only database Quarry shows in a file.
    public static let mainDatabase = "main"

    public func isInMemory(_ database: String) -> Bool { database.lowercased() == "temp" }

    // MARK: Catalog

    public func databases(_ run: SQLRunner) async throws -> [String] { [Self.mainDatabase] }

    public func useSQL(_ database: String) -> String? { nil }

    public var currentDatabaseSQL: String { "SELECT 'main'" }

    /// Objects SQLite makes itself (sqlite_sequence, sqlite_stat1) stay out of the sidebar.
    static let userObjects = "name NOT LIKE 'sqlite\\_%' ESCAPE '\\'"

    public func tablesAndViews(in database: String, _ run: SQLRunner) async throws -> [DBObject] {
        let result = try await run("SELECT name, type FROM \(identifier(database)).sqlite_schema "
            + "WHERE type IN ('table', 'view') AND \(Self.userObjects) ORDER BY name")
        return DBObject.sorted(result.rows.compactMap { row in
            guard row.count >= 2, let name = row[0].plainText, let type = row[1].plainText else { return nil }
            return DBObject(name: name, kind: type == "view" ? .view : .table)
        })
    }

    /// SQLite has no procedures or functions.
    public func routines(in database: String, _ run: SQLRunner) async throws -> [DBObject] { [] }

    public func fields(of table: String, in database: String, _ run: SQLRunner) async throws -> [FieldInfo] {
        let result = try await run("SELECT name, type, \"notnull\", dflt_value, pk FROM "
            + "pragma_table_info(\(literal(table)), \(literal(database))) ORDER BY cid")
        let create = try await createSQL(of: table, in: database, run)
        let parsed = SQLiteTable(sql: create)
        let keyCount = result.rows.indices.filter { (result.string($0, "pk").flatMap(Int.init) ?? 0) > 0 }.count
        return result.rows.indices.map { row in
            let type = result.string(row, "type") ?? ""
            let isKey = (result.string(row, "pk").flatMap(Int.init) ?? 0) > 0
            // A lone INTEGER PRIMARY KEY is the rowid; AUTOINCREMENT never reuses one.
            let isRowID = isKey && keyCount == 1 && type.uppercased() == "INTEGER"
            let extra = isRowID ? (create.range(of: "AUTOINCREMENT", options: .caseInsensitive) != nil ? "autoincrement" : "rowid") : ""
            let name = result.string(row, "name") ?? ""
            let column = parsed?.column(named: name).map { parsed!.columns[$0] }
            return FieldInfo(name: name, fullType: type,
                             isNullable: result.string(row, "notnull") == "0" && !isKey,
                             key: isKey ? "PRI" : "", defaultValue: Self.defaultValue(result.string(row, "dflt_value")),
                             extra: extra, collation: column?.collation, comment: "")
        }
    }

    /// SHOW INDEX's columns: the primary key first (as PRIMARY), then each index's fields in order.
    public func indexes(of table: String, in database: String, _ run: SQLRunner) async throws -> StatementResult {
        let names = ["Table", "Non_unique", "Key_name", "Seq_in_index", "Column_name", "Collation", "Cardinality",
                     "Sub_part", "Packed", "Null", "Index_type", "Comment"]
        var rows: [[CellValue]] = []
        func add(_ key: String, unique: Bool, seq: Int, column: String) {
            rows.append([.text(table), .text(unique ? "0" : "1"), .text(key), .text(String(seq)), .text(column),
                         .text("A"), .null, .null, .null, .text(""), .text("BTREE"), .text("")])
        }
        let keys = try await run("SELECT name, pk FROM pragma_table_info(\(literal(table)), \(literal(database))) "
            + "WHERE pk > 0 ORDER BY pk")
        for (seq, row) in keys.rows.indices.enumerated() { add("PRIMARY", unique: true, seq: seq + 1, column: keys.string(row, "name") ?? "") }
        let list = try await run("SELECT name, \"unique\", origin FROM pragma_index_list(\(literal(table)), \(literal(database))) "
            + "WHERE origin <> 'pk' ORDER BY name")
        for row in list.rows.indices {
            guard let index = list.string(row, "name") else { continue }
            let parts = try await run("SELECT name FROM pragma_index_info(\(literal(index)), \(literal(database))) ORDER BY seqno")
            for (seq, part) in parts.rows.indices.enumerated() {
                // An index on an expression has no field name.
                add(index, unique: list.string(row, "unique") == "1", seq: seq + 1, column: parts.string(part, "name") ?? "<expression>")
            }
        }
        return StatementResult(sql: "", columns: names.map { ResultColumn(name: $0) }, rows: rows, affectedRows: nil, duration: .zero)
    }

    public func foreignKeys(of table: String, in database: String, _ run: SQLRunner) async throws -> [ForeignKeyInfo] {
        let result = try await run("SELECT id, \"table\" AS ref_table, \"from\", \"to\", on_update, on_delete FROM "
            + "pragma_foreign_key_list(\(literal(table)), \(literal(database))) ORDER BY id, seq")
        var order: [String] = []
        var keys: [String: ForeignKeyInfo] = [:]
        var primaryKeys: [String: [String]] = [:]
        var seqs: [String: Int] = [:]
        for row in result.rows.indices {
            let id = result.string(row, "id") ?? "0"
            let from = result.string(row, "from") ?? ""
            let seq = seqs[id, default: 0]
            seqs[id] = seq + 1
            // `to` is NULL when the key names the other table's primary key: REFERENCES customers.
            var to = result.string(row, "to") ?? ""
            if to.isEmpty, let other = result.string(row, "ref_table") {
                if primaryKeys[other] == nil {
                    primaryKeys[other] = try await run("SELECT name FROM pragma_table_info(\(literal(other)), \(literal(database))) "
                        + "WHERE pk > 0 ORDER BY pk").rows.compactMap { $0.first?.plainText }
                }
                let key = primaryKeys[other] ?? []
                to = seq < key.count ? key[seq] : ""
            }
            if var key = keys[id] {
                key.columns += ", " + from
                key.referencedColumns += ", " + to
                keys[id] = key
            } else {
                order.append(id)
                keys[id] = ForeignKeyInfo(name: Self.foreignKeyName(table: table, id: Int(id) ?? 0), columns: from,
                                          referencedDatabase: database, referencedTable: result.string(row, "ref_table") ?? "",
                                          referencedColumns: to, onUpdate: result.string(row, "on_update") ?? "",
                                          onDelete: result.string(row, "on_delete") ?? "")
            }
        }
        return order.compactMap { keys[$0] }
    }

    /// SQLite's foreign keys have no names; Quarry calls them by table and number, as MySQL would.
    public static func foreignKeyName(table: String, id: Int) -> String { "\(table)_fk_\(id + 1)" }

    public func tableEngines(in database: String, _ run: SQLRunner) async throws -> [String: String] { [:] }

    public func latestForeignKeyError(_ run: SQLRunner) async -> String? { nil }

    /// SHOW TRIGGERS' columns, from each trigger's CREATE TRIGGER text.
    public func triggers(of table: String, in database: String, _ run: SQLRunner) async throws -> StatementResult {
        let result = try await run("SELECT name, sql FROM \(identifier(database)).sqlite_schema WHERE type = 'trigger' "
            + "AND tbl_name = \(literal(table)) ORDER BY name")
        let names = ["Trigger", "Event", "Table", "Statement", "Timing", "Created", "sql_mode", "Definer", "Columns"]
        let rows: [[CellValue]] = result.rows.indices.map { row in
            let parsed = SQLiteTrigger(result.string(row, "sql") ?? "")
            return [.text(result.string(row, "name") ?? ""), .text(parsed.event), .text(table), .text(parsed.statement),
                    .text(parsed.timing), .null, .text(""), .text(""), .text(parsed.columns)]
        }
        return StatementResult(sql: result.sql, columns: names.map { ResultColumn(name: $0) }, rows: rows,
                               affectedRows: nil, duration: result.duration)
    }

    public func triggerNames(in database: String, _ run: SQLRunner) async throws -> [String] {
        try await run("SELECT name FROM \(identifier(database)).sqlite_schema WHERE type = 'trigger'").rows
            .compactMap { $0.first?.plainText }
    }

    /// SHOW TABLE STATUS's Name and Rows; SQLite keeps no engine, sizes or comment per table.
    public func tableStatus(of table: String, in database: String, _ run: SQLRunner) async throws -> StatementResult {
        let count = try await run(countSQL(table: table, database: database, where: nil))
        let names = ["Name", "Engine", "Rows", "Collation", "Comment"]
        return StatementResult(sql: count.sql, columns: names.map { ResultColumn(name: $0) },
                               rows: [[.text(table), .text(""), count.rows.first?.first ?? .null, .text(""), .text("")]],
                               affectedRows: nil, duration: count.duration)
    }

    public func createStatement(of object: DBObject, in database: String, _ run: SQLRunner) async throws -> String {
        let create = try await createSQL(of: object.name, in: database, run)
        return create.isEmpty ? "" : create + ";"
    }

    private func createSQL(of name: String, in database: String, _ run: SQLRunner) async throws -> String {
        try await createStatement(kind: "", of: name, in: database, run) ?? ""
    }

    /// From sqlite_schema; every kind (table, view, index, trigger) keeps its own CREATE there.
    public func createStatement(kind: String, of name: String, in database: String, _ run: SQLRunner) async throws -> String? {
        try await run("SELECT sql FROM \(identifier(database)).sqlite_schema WHERE name = \(literal(name))")
            .rows.first?.first?.plainText.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Rows

    public func countSQL(table: String, database: String, where condition: String?) -> String {
        var sql = "SELECT COUNT(*) FROM " + qualified(database, table)
        if let condition { sql += " WHERE " + condition }
        return sql
    }

    public func pageSQL(table: String, database: String, where condition: String? = nil, orderBy column: String?,
                        ascending: Bool, offset: Int, limit: Int, rowID: String? = nil) -> String {
        var sql = "SELECT " + (rowID.map { identifier($0) + ", " } ?? "") + "* FROM " + qualified(database, table)
        if let condition { sql += " WHERE " + condition }
        if let column { sql += " ORDER BY \(identifier(column)) \(ascending ? "ASC" : "DESC")" }
        sql += " LIMIT \(max(1, limit)) OFFSET \(max(0, offset))"
        return sql
    }

    /// The name that reaches a table's rowid: `rowid`, unless a column has that
    /// name, then `_rowid_` or `oid`; nil when columns have all three (S-069).
    public static func rowIDName(avoiding columns: [String]) -> String? {
        let taken = Set(columns.map { $0.lowercased() })
        return ["rowid", "_rowid_", "oid"].first { !taken.contains($0) }
    }

    /// A default as PRAGMA table_info gives it, as MySQL gives one: 'US' as US,
    /// 'it''s' as it's; numbers, NULL and expressions (CURRENT_TIMESTAMP) as written.
    public static func defaultValue(_ sql: String?) -> String? {
        guard let sql else { return nil }
        let text = sql.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") else { return text }
        let inner = text.dropFirst().dropLast()
        // 'a' || 'b' is an expression, not one literal.
        guard !inner.replacingOccurrences(of: "''", with: "").contains("'") else { return text }
        return inner.replacingOccurrences(of: "''", with: "'")
    }

    /// SQLite text is always UTF-8 here.
    public func viewEncodingSQL(_ encoding: ViewEncoding) -> String? { nil }

    // MARK: Export (S-071)

    /// BEGIN alone waits for the first read; reading the schema takes the snapshot now.
    public var snapshotBeginSQL: [String] { ["BEGIN", "SELECT count(*) FROM sqlite_schema"] }

    // MARK: Agents (S-073)

    public var readOnlyBeginSQL: String { "BEGIN" }
    public var rollbackSQL: String { "ROLLBACK" }

    public func explainSQL(_ statement: String) -> String { "EXPLAIN QUERY PLAN " + statement }

    public func sampleSQL(table: String, database: String, limit: Int) -> String {
        "SELECT * FROM \(qualified(database, table)) LIMIT \(limit)"
    }

    private func schema(_ database: String) -> String { identifier(database) + ".sqlite_schema" }

    public func agentTablesSQL(in database: String) -> String {
        "SELECT name, CASE type WHEN 'view' THEN 'VIEW' ELSE 'BASE TABLE' END AS type, '' AS engine, "
            + "NULL AS rows_estimate, '' AS comment FROM \(schema(database)) WHERE type IN ('table', 'view') "
            + "AND \(Self.userObjects) ORDER BY name"
    }

    public func agentRoutinesSQL(in database: String) -> String? { nil }

    public func agentTriggersSQL(in database: String) -> String {
        "SELECT name, tbl_name AS \"table\", '' AS timing, '' AS event, sql AS statement FROM \(schema(database)) "
            + "WHERE type = 'trigger' ORDER BY name"
    }

    public func agentEventsSQL(in database: String) -> String? { nil }

    public func objectTypeSQL(of name: String, in database: String) -> String {
        "SELECT CASE type WHEN 'view' THEN 'VIEW' ELSE 'BASE TABLE' END FROM \(schema(database)) "
            + "WHERE type IN ('table', 'view') AND name = \(literal(name))"
    }

    public func objectKindSQL(of name: String, in database: String) -> String {
        "SELECT type FROM \(schema(database)) WHERE type IN ('table', 'view', 'trigger') AND name = \(literal(name))"
    }

    /// Sizes from the dbstat table, one row per b-tree: a table's own pages, its indexes' pages,
    /// and the bytes left unused in both.
    public func tableSizesSQL(in database: String) -> String {
        "WITH s AS MATERIALIZED (SELECT name, pgsize, unused FROM dbstat(\(literal(database)), 1)), "
            + "o AS (SELECT name, tbl_name, type FROM \(schema(database))) "
            + "SELECT t.name, '' AS engine, NULL AS rows_estimate, "
            + "coalesce((SELECT sum(pgsize) FROM s WHERE s.name = t.name), 0) AS data, "
            + "coalesce((SELECT sum(s.pgsize) FROM s JOIN o ON o.name = s.name WHERE o.type = 'index' AND o.tbl_name = t.name), 0) AS idx, "
            + "coalesce((SELECT sum(s.unused) FROM s JOIN o ON o.name = s.name WHERE o.tbl_name = t.name), 0) AS free "
            + "FROM o t WHERE t.type = 'table' AND \(Self.userObjects) ORDER BY data + idx DESC, t.name"
    }

    /// The table names alone, for a SQLite built without dbstat.
    public func tableSizesFallbackSQL(in database: String) -> String? {
        "SELECT name, '' AS engine, NULL AS rows_estimate, NULL AS data, NULL AS idx, NULL AS free "
            + "FROM \(schema(database)) WHERE type = 'table' AND \(Self.userObjects) ORDER BY name"
    }

    /// The file's settings, from PRAGMA table functions, which only read.
    public var fileSettingsSQL: String? {
        Self.fileSettings.map { "SELECT '\($0)' AS Variable_name, \($0) AS Value FROM pragma_\($0)()" }
            .joined(separator: " UNION ALL ")
    }

    /// What server_info tells an agent about a SQLite file.
    public static let fileSettings = ["page_size", "page_count", "freelist_count", "journal_mode", "encoding", "auto_vacuum",
                                      "foreign_keys", "user_version", "application_id"]

    // MARK: Server: a file has none

    public var currentUserSQL: String? { nil }
    public func variablesSQL(named names: [String]) -> String? { nil }
    public var uptimeSQL: String? { nil }
    public func processListSQL(full: Bool) -> String? { nil }
    public func killSQL(_ id: Int, connection: Bool) -> String? { nil }
}

/// The timing, event and body of a CREATE TRIGGER statement as SQLite stores it.
public struct SQLiteTrigger: Sendable, Equatable {
    public var timing: String
    public var event: String
    /// UPDATE OF's fields, as written: "stock, price"; empty for any field.
    public var columns: String
    /// What follows ON table: an optional WHEN, then BEGIN … END (FOR EACH ROW left out, as SQLite has no other kind).
    public var statement: String

    public init(_ sql: String) {
        let tokens = SQLiteTokens(sql).tokens
        let words = tokens.map(\.upper)
        let on = words.firstIndex(of: "ON")
        let head = on.map { Array(words[..<$0]) } ?? words
        func first(_ options: [String]) -> Int? { head.firstIndex { options.contains($0) } }
        if let at = first(["INSTEAD"]) , at + 1 < head.count, head[at + 1] == "OF" { timing = "INSTEAD OF" }
        else { timing = first(["BEFORE", "AFTER"]).map { head[$0] } ?? "BEFORE" }
        let eventAt = first(["INSERT", "UPDATE", "DELETE"])
        event = eventAt.map { head[$0] } ?? ""
        columns = ""
        if let eventAt, let on, eventAt + 2 < on, words[eventAt + 1] == "OF" {
            columns = SQLiteTokens.text(sql, Array(tokens[(eventAt + 2)..<on]))
        }
        guard let on, on + 1 < tokens.count else { statement = sql; return }
        var rest = on + 2
        if rest + 2 < tokens.count, words[rest] == "FOR", words[rest + 1] == "EACH", words[rest + 2] == "ROW" { rest += 3 }
        statement = rest < tokens.count ? String(sql[tokens[rest].range.lowerBound...]) : ""
    }
}
