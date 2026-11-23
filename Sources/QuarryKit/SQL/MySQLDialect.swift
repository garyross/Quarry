import Foundation

/// MySQL's and MariaDB's SQL for the catalog and agents (S-067).
public struct MySQLDialect: SQLDialect {
    public init() {}

    public var engine: Engine { .mysql }

    public func isInMemory(_ database: String) -> Bool {
        ["information_schema", "performance_schema"].contains(database.lowercased())
    }

    // MARK: Catalog

    public func databases(_ run: SQLRunner) async throws -> [String] {
        try await run("SHOW DATABASES").rows.compactMap { $0.first?.plainText }
    }

    public func useSQL(_ database: String) -> String? { "USE " + identifier(database) }

    public var currentDatabaseSQL: String { "SELECT DATABASE()" }

    public func tablesAndViews(in database: String, _ run: SQLRunner) async throws -> [DBObject] {
        let tables = try await run("SHOW FULL TABLES FROM " + identifier(database))
        return DBObject.sorted(tables.rows.compactMap { row in
            guard row.count >= 2, let name = row[0].plainText, let type = row[1].plainText,
                  let kind = ObjectKind(serverType: type) else { return nil }
            return DBObject(name: name, kind: kind)
        })
    }

    /// Procedures and functions. This reads `mysql.proc`, which fails on a
    /// server whose system tables were not upgraded, so callers load it apart
    /// from the tables.
    public func routines(in database: String, _ run: SQLRunner) async throws -> [DBObject] {
        let routines = try await run(
            "SELECT ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = "
                + literal(database) + " ORDER BY ROUTINE_NAME")
        return DBObject.sorted(routines.rows.compactMap { row in
            guard let name = row[0].plainText, let type = row[1].plainText, let kind = ObjectKind(serverType: type) else { return nil }
            return DBObject(name: name, kind: kind)
        })
    }

    public func fields(of table: String, in database: String, _ run: SQLRunner) async throws -> [FieldInfo] {
        let result = try await run("SHOW FULL COLUMNS FROM " + qualified(database, table))
        return result.rows.indices.map { row in
            FieldInfo(name: result.string(row, "Field") ?? "",
                      fullType: result.string(row, "Type") ?? "",
                      isNullable: result.string(row, "Null") == "YES",
                      key: result.string(row, "Key") ?? "",
                      defaultValue: result.string(row, "Default"),
                      extra: result.string(row, "Extra") ?? "",
                      collation: result.string(row, "Collation"),
                      comment: result.string(row, "Comment") ?? "")
        }
    }

    public func indexes(of table: String, in database: String, _ run: SQLRunner) async throws -> StatementResult {
        try await run("SHOW INDEX FROM " + qualified(database, table))
    }

    public func foreignKeys(of table: String, in database: String, _ run: SQLRunner) async throws -> [ForeignKeyInfo] {
        let result = try await run("""
            SELECT k.CONSTRAINT_NAME AS name,
                   GROUP_CONCAT(k.COLUMN_NAME ORDER BY k.ORDINAL_POSITION SEPARATOR ', ') AS columns,
                   k.REFERENCED_TABLE_SCHEMA AS ref_db, k.REFERENCED_TABLE_NAME AS ref_table,
                   GROUP_CONCAT(k.REFERENCED_COLUMN_NAME ORDER BY k.ORDINAL_POSITION SEPARATOR ', ') AS ref_columns,
                   r.UPDATE_RULE AS on_update, r.DELETE_RULE AS on_delete
            FROM information_schema.KEY_COLUMN_USAGE k
            JOIN information_schema.REFERENTIAL_CONSTRAINTS r
              ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
             AND r.TABLE_NAME = k.TABLE_NAME
            WHERE k.TABLE_SCHEMA = \(literal(database)) AND k.TABLE_NAME = \(literal(table))
              AND k.REFERENCED_TABLE_NAME IS NOT NULL
            GROUP BY k.CONSTRAINT_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME, r.UPDATE_RULE, r.DELETE_RULE
            ORDER BY k.CONSTRAINT_NAME
            """)
        return result.rows.indices.map { row in
            ForeignKeyInfo(name: result.string(row, "name") ?? "", columns: result.string(row, "columns") ?? "",
                           referencedDatabase: result.string(row, "ref_db") ?? "",
                           referencedTable: result.string(row, "ref_table") ?? "",
                           referencedColumns: result.string(row, "ref_columns") ?? "",
                           onUpdate: result.string(row, "on_update") ?? "", onDelete: result.string(row, "on_delete") ?? "")
        }
    }

    public func tableEngines(in database: String, _ run: SQLRunner) async throws -> [String: String] {
        let result = try await run("""
            SELECT TABLE_NAME AS name, ENGINE AS engine FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = \(literal(database)) AND TABLE_TYPE = 'BASE TABLE'
            """)
        var engines: [String: String] = [:]
        for row in result.rows.indices {
            engines[result.string(row, "name") ?? ""] = result.string(row, "engine") ?? ""
        }
        return engines
    }

    /// InnoDB's explanation of the last foreign key it refused (needs PROCESS; errors give nil).
    public func latestForeignKeyError(_ run: SQLRunner) async -> String? {
        guard let result = try? await run("SHOW ENGINE INNODB STATUS"),
              let status = result.string(0, "Status") else { return nil }
        return InnoDBStatus.latestForeignKeyError(status)
    }

    public func triggers(of table: String, in database: String, _ run: SQLRunner) async throws -> StatementResult {
        try await run("SHOW TRIGGERS FROM \(identifier(database)) WHERE `Table` = \(literal(table))")
    }

    /// Names are unique in a database, not per table (S-026).
    public func triggerNames(in database: String, _ run: SQLRunner) async throws -> [String] {
        let result = try await run("SELECT TRIGGER_NAME AS n FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = "
            + literal(database))
        return result.rows.indices.compactMap { result.string($0, "n") }
    }

    public func tableStatus(of table: String, in database: String, _ run: SQLRunner) async throws -> StatementResult {
        try await run("SHOW TABLE STATUS FROM \(identifier(database)) WHERE Name = \(literal(table))")
    }

    public func createStatement(of object: DBObject, in database: String, _ run: SQLRunner) async throws -> String {
        try await createStatement(kind: object.kind.rawValue, of: object.name, in: database, run) ?? ""
    }

    public func createStatement(kind: String, of name: String, in database: String, _ run: SQLRunner) async throws -> String? {
        let result = try await run("SHOW CREATE \(kind.uppercased()) \(qualified(database, name))")
        // In the column whose name starts with "Create", or SHOW CREATE TRIGGER's "SQL Original Statement".
        guard let index = result.columns.firstIndex(where: { $0.name.hasPrefix("Create") || $0.name == "SQL Original Statement" }),
              let row = result.rows.first else { return nil }
        return row[index].plainText
    }

    // MARK: Rows

    public func countSQL(table: String, database: String, where condition: String?) -> String {
        var sql = "SELECT COUNT(*) FROM " + qualified(database, table)
        if let condition { sql += " WHERE " + condition }
        return sql
    }

    public func pageSQL(table: String, database: String, where condition: String? = nil, orderBy column: String?,
                        ascending: Bool, offset: Int, limit: Int, rowID: String? = nil) -> String {
        var sql = "SELECT * FROM " + qualified(database, table)
        if let condition { sql += " WHERE " + condition }
        if let column { sql += " ORDER BY \(identifier(column)) \(ascending ? "ASC" : "DESC")" }
        sql += " LIMIT \(max(0, offset)), \(max(1, limit))"
        return sql
    }

    public func viewEncodingSQL(_ encoding: ViewEncoding) -> String? { "SET NAMES " + encoding.charset }

    // MARK: Agents

    public var snapshotBeginSQL: [String] {
        ["SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ", "START TRANSACTION WITH CONSISTENT SNAPSHOT"]
    }

    public var readOnlyBeginSQL: String { "START TRANSACTION READ ONLY" }
    public var rollbackSQL: String { "ROLLBACK" }

    public func explainSQL(_ statement: String) -> String { "EXPLAIN " + statement }

    public func sampleSQL(table: String, database: String, limit: Int) -> String {
        "SELECT * FROM \(qualified(database, table)) LIMIT \(limit)"
    }

    public func agentTablesSQL(in database: String) -> String {
        "SELECT TABLE_NAME AS name, TABLE_TYPE AS type, ENGINE AS engine, TABLE_ROWS AS rows_estimate, "
            + "TABLE_COMMENT AS comment FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(literal(database)) "
            + "ORDER BY TABLE_NAME"
    }

    public func agentRoutinesSQL(in database: String) -> String? {
        "SELECT ROUTINE_NAME AS name, ROUTINE_TYPE AS kind, DTD_IDENTIFIER AS returns, "
            + "ROUTINE_COMMENT AS comment FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(literal(database)) ORDER BY ROUTINE_NAME"
    }

    public func agentTriggersSQL(in database: String) -> String {
        "SELECT TRIGGER_NAME AS name, EVENT_OBJECT_TABLE AS `table`, ACTION_TIMING AS timing, "
            + "EVENT_MANIPULATION AS event FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = \(literal(database)) ORDER BY TRIGGER_NAME"
    }

    public func agentEventsSQL(in database: String) -> String? {
        "SELECT EVENT_NAME AS name, STATUS AS status, EVENT_TYPE AS type, "
            + "INTERVAL_VALUE AS every, INTERVAL_FIELD AS unit FROM information_schema.EVENTS WHERE EVENT_SCHEMA = \(literal(database)) ORDER BY EVENT_NAME"
    }

    public func objectTypeSQL(of name: String, in database: String) -> String {
        "SELECT TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = "
            + literal(database) + " AND TABLE_NAME = " + literal(name)
    }

    public func objectKindSQL(of name: String, in database: String) -> String {
        """
        SELECT IF(TABLE_TYPE LIKE '%VIEW', 'view', 'table') FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(literal(database)) AND TABLE_NAME = \(literal(name))
        UNION ALL SELECT LOWER(ROUTINE_TYPE) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(literal(database)) AND ROUTINE_NAME = \(literal(name))
        UNION ALL SELECT 'trigger' FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = \(literal(database)) AND TRIGGER_NAME = \(literal(name))
        """
    }

    public func tableSizesSQL(in database: String) -> String {
        "SELECT TABLE_NAME AS name, ENGINE AS engine, TABLE_ROWS AS rows_estimate, DATA_LENGTH AS data, "
            + "INDEX_LENGTH AS idx, DATA_FREE AS free FROM information_schema.TABLES WHERE TABLE_SCHEMA = "
            + literal(database) + " AND TABLE_TYPE <> 'VIEW' ORDER BY DATA_LENGTH + INDEX_LENGTH DESC, TABLE_NAME"
    }

    // MARK: Server

    public var currentUserSQL: String? { "SELECT CURRENT_USER()" }

    public func variablesSQL(named names: [String]) -> String? {
        "SHOW GLOBAL VARIABLES WHERE Variable_name IN (\(names.map(literal).joined(separator: ", ")))"
    }

    public var uptimeSQL: String? { "SHOW GLOBAL STATUS LIKE 'Uptime'" }

    public func processListSQL(full: Bool) -> String? { full ? "SHOW FULL PROCESSLIST" : "SHOW PROCESSLIST" }

    public func killSQL(_ id: Int, connection: Bool) -> String? { connection ? "KILL \(id)" : "KILL QUERY \(id)" }
}
