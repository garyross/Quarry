import Foundation

/// Queries for the Database Information panel. Read-only except `repair`.
extension DatabaseClient {
    /// Size, character set, engines and counts for one database.
    public func overview(of database: String) async throws -> DatabaseOverview {
        let schema = try await run(
            "SELECT DEFAULT_CHARACTER_SET_NAME AS cs, DEFAULT_COLLATION_NAME AS co FROM information_schema.SCHEMATA "
                + "WHERE SCHEMA_NAME = " + SQLQuote.mysqlLiteral(database))
        let stats = try await run("""
            SELECT TABLE_NAME AS name, TABLE_TYPE AS type, ENGINE AS engine, TABLE_ROWS AS row_count,
                   DATA_LENGTH AS data, INDEX_LENGTH AS idx, DATA_FREE AS free, TABLE_COLLATION AS collation
            FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(SQLQuote.mysqlLiteral(database)) ORDER BY TABLE_NAME
            """)
        let objects = stats.rows.indices.map { row in
            TableStat(name: stats.string(row, "name") ?? "",
                      isView: stats.string(row, "type") == "VIEW",
                      engine: stats.string(row, "engine"),
                      rows: stats.string(row, "row_count").flatMap { Int($0) },
                      dataBytes: stats.string(row, "data").flatMap { Int($0) } ?? 0,
                      indexBytes: stats.string(row, "idx").flatMap { Int($0) } ?? 0,
                      freeBytes: stats.string(row, "free").flatMap { Int($0) } ?? 0,
                      collation: stats.string(row, "collation"))
        }
        var routineCount: Int?
        var routinesError: DatabaseError?
        do {
            routineCount = try await routines(in: database).count
        } catch {
            routinesError = DatabaseError.from(error)
        }
        return DatabaseOverview(name: database, charset: schema.string(0, "cs") ?? "", collation: schema.string(0, "co") ?? "",
                                objects: objects, routineCount: routineCount, routinesError: routinesError)
    }

    /// Every text column in the database's tables (views left out).
    public func textColumns(in database: String) async throws -> [ColumnCharset] {
        let result = try await run("""
            SELECT c.TABLE_NAME AS t, c.COLUMN_NAME AS c, c.CHARACTER_SET_NAME AS cs, c.COLLATION_NAME AS co
            FROM information_schema.COLUMNS c
            JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
            WHERE c.TABLE_SCHEMA = \(SQLQuote.mysqlLiteral(database)) AND t.TABLE_TYPE <> 'VIEW'
              AND c.COLLATION_NAME IS NOT NULL
            ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION
            """)
        return result.rows.indices.map { row in
            ColumnCharset(table: result.string(row, "t") ?? "", column: result.string(row, "c") ?? "",
                          charset: result.string(row, "cs") ?? "", collation: result.string(row, "co") ?? "")
        }
    }

    /// Find Collations.
    public func collationReport(for overview: DatabaseOverview) async throws -> CollationReport {
        CollationReport(database: overview.name, defaultCharset: overview.charset, defaultCollation: overview.collation,
                        columns: try await textColumns(in: overview.name), tables: overview.objects)
    }

    /// What the Health Check needs, read in a few queries.
    public func healthInput(for overview: DatabaseOverview) async throws -> HealthInput {
        let database = SQLQuote.mysqlLiteral(overview.name)
        let keys = try await run(
            "SELECT DISTINCT TABLE_NAME AS t FROM information_schema.TABLE_CONSTRAINTS "
                + "WHERE TABLE_SCHEMA = \(database) AND CONSTRAINT_TYPE = 'PRIMARY KEY'")
        let auto = try await run("""
            SELECT c.TABLE_NAME AS t, c.COLUMN_NAME AS c, c.COLUMN_TYPE AS type, t.AUTO_INCREMENT AS next
            FROM information_schema.COLUMNS c
            JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
            WHERE c.TABLE_SCHEMA = \(database) AND c.EXTRA LIKE '%auto_increment%' AND t.AUTO_INCREMENT IS NOT NULL
            """)
        return HealthInput(
            overview: overview,
            columns: try await textColumns(in: overview.name),
            tablesWithPrimaryKey: Set(keys.rows.indices.compactMap { keys.string($0, "t") }),
            autoIncrements: auto.rows.indices.compactMap { row in
                guard let table = auto.string(row, "t"), let column = auto.string(row, "c"),
                      let type = auto.string(row, "type"), let next = auto.string(row, "next").flatMap({ Int($0) }) else { return nil }
                return AutoIncrementColumn(table: table, column: column, type: type, next: next)
            },
            isMariaDB: serverVersion.localizedCaseInsensitiveContains("mariadb"))
    }

    /// CHECK TABLE for one table. Reads only, but holds a read lock while it runs.
    public func check(_ table: String, in database: String) async throws -> TableCheck {
        try await maintenance("CHECK TABLE", table, in: database)
    }

    /// Repairs one table: REPAIR TABLE for engines that support it (MyISAM,
    /// Aria, Archive, CSV), and a rebuild (ALTER TABLE … FORCE) for InnoDB,
    /// which has no REPAIR. Locks the table while it runs.
    public func repair(_ table: TableStat, in database: String) async throws -> TableCheck {
        if table.isInnoDB {
            _ = try await run("ALTER TABLE \(SQLQuote.qualified(database, table.name)) FORCE")
            let after = try await check(table.name, in: database)
            return TableCheck(table: table.name, severity: after.severity,
                              message: after.severity == .ok ? "Rebuilt; the check now passes" : "Rebuilt, but: \(after.message)")
        }
        return try await maintenance("REPAIR TABLE", table.name, in: database)
    }

    /// Table > Maintenance (S-029): one statement for every table. Flush
    /// returns no rows, so each table is "Flushed" when it succeeds.
    public func run(_ operation: TableOperation, on tables: [String], in database: String) async throws -> [TableCheck] {
        guard !tables.isEmpty else { return [] }
        if dialect.engine == .sqlite { return try await runOnSQLite(operation, on: tables) }
        let result = try await run(operation.sql(tables, in: database))
        switch operation {
        case .flush:
            return tables.map { TableCheck(table: $0, severity: .ok, message: "Flushed") }
        case .checksum:
            let rows = result.rows.indices.map { (table: result.string($0, "Table") ?? "", checksum: result.string($0, "Checksum")) }
            return TableOperation.checksums(tables: tables, in: database, rows: rows)
        default:
            let rows = result.rows.indices.map {
                (table: result.string($0, "Table") ?? "", type: result.string($0, "Msg_type") ?? "",
                 text: result.string($0, "Msg_text") ?? "")
            }
            return operation.results(tables: tables, in: database, rows: rows)
        }
    }

    /// S-072: SQLite runs one statement per table. Check's rows are "ok" or what is wrong.
    private func runOnSQLite(_ operation: TableOperation, on tables: [String]) async throws -> [TableCheck] {
        var results: [TableCheck] = []
        for table in tables {
            guard let sql = operation.sqliteSQL(table) else { continue }
            let result = try await run(sql)
            if operation == .analyze {
                results.append(TableCheck(table: table, severity: .ok, message: "Statistics updated"))
                continue
            }
            let messages = result.rows.indices.compactMap { result.string($0, result.columns.first?.name ?? "") }
            let problems = messages.filter { $0.lowercased() != "ok" }
            results.append(problems.isEmpty ? TableCheck(table: table, severity: .ok, message: "OK")
                : TableCheck(table: table, severity: .error,
                             message: problems[0] + (problems.count > 1 ? " (and \(problems.count - 1) more)" : "")))
        }
        return results
    }

    private func maintenance(_ command: String, _ table: String, in database: String) async throws -> TableCheck {
        let result = try await run("\(command) \(SQLQuote.qualified(database, table))")
        let rows = result.rows.indices.map { (type: result.string($0, "Msg_type") ?? "", text: result.string($0, "Msg_text") ?? "") }
        return TableCheck.parse(table: table, rows: rows)
    }
}
