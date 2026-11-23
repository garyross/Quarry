import Foundation

/// S-072: Database Information on a SQLite file. Integrity Check, Foreign Key
/// Check and the Health Check only read; Vacuum, Analyze and Optimize write.
extension DatabaseClient {
    static let sqliteSchema = "\"main\".sqlite_schema"

    /// The file's size, pages and settings, and what it holds.
    public func sqliteFileInfo() async throws -> SQLiteFileInfo {
        let settings = try await run("""
            SELECT (SELECT page_size FROM pragma_page_size()) AS page_size,
                   (SELECT page_count FROM pragma_page_count()) AS page_count,
                   (SELECT freelist_count FROM pragma_freelist_count()) AS free_pages,
                   (SELECT journal_mode FROM pragma_journal_mode()) AS journal_mode,
                   (SELECT encoding FROM pragma_encoding()) AS encoding,
                   (SELECT foreign_keys FROM pragma_foreign_keys()) AS foreign_keys,
                   sqlite_version() AS version
            """)
        let objects = try await run("SELECT type, name FROM \(Self.sqliteSchema) WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name")
        func names(_ type: String) -> [String] {
            objects.rows.indices.filter { objects.string($0, "type") == type }.compactMap { objects.string($0, "name") }
        }
        func number(_ column: String) -> Int { settings.string(0, column).flatMap { Int($0) } ?? 0 }
        let url = details.fileURL
        let size = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }
        return SQLiteFileInfo(
            fileName: url?.lastPathComponent ?? "SQLite File",
            fileBytes: size ?? number("page_size") * number("page_count"),
            pageSize: number("page_size"), pageCount: number("page_count"), freePages: number("free_pages"),
            journalMode: settings.string(0, "journal_mode") ?? "", encoding: settings.string(0, "encoding") ?? "",
            foreignKeys: number("foreign_keys") != 0, version: settings.string(0, "version") ?? serverVersion,
            tables: names("table"), viewCount: names("view").count, indexCount: names("index").count,
            triggerCount: names("trigger").count, isReadOnly: details.readOnly)
    }

    /// Index names (automatic ones too) and the table each belongs to.
    func sqliteIndexTables() async throws -> [String: String] {
        let result = try await run("SELECT name, tbl_name FROM \(Self.sqliteSchema) WHERE type = 'index'")
        var map: [String: String] = [:]
        for row in result.rows.indices {
            if let name = result.string(row, "name"), let table = result.string(row, "tbl_name") { map[name] = table }
        }
        return map
    }

    /// Integrity Check: `PRAGMA integrity_check` over the whole file, its
    /// messages put under the table they name. Empty when the file is fine.
    public func sqliteIntegrityCheck(_ info: SQLiteFileInfo) async throws -> [TableCheck] {
        let result = try await run("PRAGMA \"main\".integrity_check")
        let messages = result.rows.indices.compactMap { result.string($0, result.columns.first?.name ?? "integrity_check") }
        return SQLiteIntegrity.results(messages: messages, fileName: info.fileName, tables: info.tables,
                                       indexes: try await sqliteIndexTables())
    }

    /// Foreign Key Check, one table at a time, so a table whose foreign key
    /// can't be checked ("foreign key mismatch") doesn't hide the others.
    public func sqliteForeignKeyCheck(_ tables: [String], progress: (@Sendable (String, Int) async -> Void)? = nil) async throws -> [TableCheck] {
        var checks: [TableCheck] = []
        for (index, table) in tables.enumerated() {
            try Task.checkCancellation()
            await progress?(table, index)
            do {
                let result = try await run("PRAGMA \"main\".foreign_key_check(\(SQLQuote.identifier(table)))")
                let problems = result.rows.indices.map { row in
                    SQLiteKeyProblem(table: result.string(row, "table") ?? table,
                                     rowid: result.string(row, "rowid").flatMap { Int($0) },
                                     parent: result.string(row, "parent") ?? "")
                }
                checks.append(SQLiteIntegrity.keyCheck(table: table, problems: problems))
            } catch let error as DatabaseError where !isClosed {
                checks.append(TableCheck(table: table, severity: .error, message: error.message))
            }
        }
        return checks
    }

    /// What the SQLite Health Check reads.
    public func sqliteHealthInput(_ info: SQLiteFileInfo) async throws -> SQLiteHealthInput {
        let tables = "FROM \(Self.sqliteSchema) m WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite\\_%' ESCAPE '\\'"
        let keys = try await run("SELECT m.name AS t, p.name AS c FROM (SELECT name \(tables)) m JOIN pragma_table_info(m.name) p "
                                 + "WHERE p.pk > 0 ORDER BY m.name, p.pk")
        let foreign = try await run("SELECT m.name AS t, f.id, f.\"table\" AS parent, f.\"from\" AS c, f.\"to\" AS pc "
                                    + "FROM (SELECT name \(tables)) m JOIN pragma_foreign_key_list(m.name) f ORDER BY m.name, f.id, f.seq")
        let indexed = try await run("SELECT m.name AS t, il.name AS i, ii.name AS c FROM (SELECT name \(tables)) m "
                                    + "JOIN pragma_index_list(m.name) il JOIN pragma_index_info(il.name) ii ORDER BY m.name, il.name, ii.seqno")

        var primary: [String: [String]] = [:]
        for row in keys.rows.indices {
            guard let table = keys.string(row, "t"), let column = keys.string(row, "c") else { continue }
            primary[table, default: []].append(column)
        }
        var indexes: [String: [[String]]] = primary.mapValues { [$0] }
        var current: (table: String, index: String, columns: [String])?
        func flush() { if let current { indexes[current.table, default: []].append(current.columns) } }
        for row in indexed.rows.indices {
            guard let table = indexed.string(row, "t"), let index = indexed.string(row, "i") else { continue }
            let column = indexed.string(row, "c") ?? ""
            if current?.table == table, current?.index == index {
                current?.columns.append(column)
            } else {
                flush()
                current = (table, index, [column])
            }
        }
        flush()

        var foreignKeys: [SQLiteForeignKey] = []
        var lastKey: String?
        for row in foreign.rows.indices {
            guard let table = foreign.string(row, "t"), let id = foreign.string(row, "id") else { continue }
            let column = foreign.string(row, "c") ?? ""
            let parentColumn = foreign.string(row, "pc")
            if lastKey == "\(table)#\(id)", var key = foreignKeys.popLast() {
                key.columns.append(column)
                if let parentColumn { key.parentColumns.append(parentColumn) }
                foreignKeys.append(key)
            } else {
                foreignKeys.append(SQLiteForeignKey(table: table, columns: [column], parent: foreign.string(row, "parent") ?? "",
                                                    parentColumns: parentColumn.map { [$0] } ?? []))
            }
            lastKey = "\(table)#\(id)"
        }

        return SQLiteHealthInput(info: info, tablesWithPrimaryKey: Set(primary.keys), foreignKeys: foreignKeys,
                                 indexes: indexes, keyProblems: try await sqliteForeignKeyCheck(info.tables))
    }

    /// Vacuum: rewrites the file without its free pages. A WAL file is
    /// checkpointed after, so the main file shows its new size.
    public func sqliteVacuum() async throws {
        _ = try await run("VACUUM \"main\"")
        _ = try? await run("PRAGMA \"main\".wal_checkpoint(TRUNCATE)")
    }

    /// Analyze: fresh statistics for the query planner, for every table.
    public func sqliteAnalyze() async throws {
        _ = try await run("ANALYZE \"main\"")
    }

    /// Optimize: ANALYZE only where SQLite thinks the statistics are stale.
    public func sqliteOptimize() async throws {
        _ = try await run("PRAGMA \"main\".optimize")
    }
}
