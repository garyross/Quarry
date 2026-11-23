import Foundation

/// Rename, duplicate, empty and delete tables and views (S-022).
public enum TableEdit {
    /// RENAME TABLE works for views too, within one database.
    public static func renameSQL(_ name: String, to newName: String, in database: String, engine: Engine) -> String {
        if engine == .sqlite { return "ALTER TABLE " + SQLiteTable.quote(name) + " RENAME TO " + SQLiteTable.quote(newName) }
        return "RENAME TABLE " + SQLQuote.qualified(database, name) + " TO " + SQLQuote.qualified(database, newName)
    }

    /// TRUNCATE TABLE; SQLite has none, and DELETE FROM with no WHERE empties a table as fast (S-070).
    public static func emptySQL(_ table: String, in database: String, engine: Engine) -> String {
        engine == .sqlite ? "DELETE FROM " + SQLiteTable.quote(table) : "TRUNCATE TABLE " + SQLQuote.qualified(database, table)
    }

    /// One DROP TABLE for the tables and one DROP VIEW for the views, so each
    /// kind goes in one statement; then a DROP PROCEDURE or DROP FUNCTION for
    /// each routine, which can't share one (S-030).
    public static func deleteSQL(_ objects: [DBObject], in database: String, engine: Engine) -> [String] {
        // SQLite drops one table or view per statement.
        if engine == .sqlite {
            return objects.filter(\.kind.hasRows).map { ($0.kind == .view ? "DROP VIEW " : "DROP TABLE ") + SQLiteTable.quote($0.name) }
        }
        let tables = objects.filter { $0.kind == .table }.map { SQLQuote.qualified(database, $0.name) }
        let views = objects.filter { $0.kind == .view }.map { SQLQuote.qualified(database, $0.name) }
        var statements: [String] = []
        if !tables.isEmpty { statements.append("DROP TABLE " + tables.joined(separator: ", ")) }
        if !views.isEmpty { statements.append("DROP VIEW " + views.joined(separator: ", ")) }
        for routine in objects where routine.kind == .procedure || routine.kind == .function {
            statements.append(DefinitionChange.dropSQL(routine.kind, routine.name, in: database))
        }
        return statements
    }

    /// A copy's CREATE TABLE, from the source's SHOW CREATE TABLE: the new
    /// name, foreign keys without their names (InnoDB wants them unique in the
    /// database, so the server makes new ones), and, without rows, no AUTO_INCREMENT=n.
    public static func copyCreateSQL(_ create: String, to newName: String, in database: String, withRows: Bool) -> String {
        var sql = create
        if let open = sql.firstIndex(of: "(") {
            sql = "CREATE TABLE " + SQLQuote.qualified(database, newName) + " " + sql[open...]
        }
        sql = sql.replacingOccurrences(of: #"CONSTRAINT `(?:[^`]|``)*` FOREIGN KEY"#, with: "FOREIGN KEY",
                                       options: .regularExpression)
        return withRows ? sql : DatabaseTransfer.withoutAutoIncrement(sql)
    }

    /// "orders_copy", or "orders_copy2" and up when that is taken (ignoring case).
    public static func copyName(for name: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        let base = String((name + "_copy").prefix(64))
        if !taken.contains(base.lowercased()) { return base }
        for number in 2... {
            let candidate = String(base.prefix(64 - String(number).count)) + String(number)
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        return base
    }

    /// True for the server's foreign-key refusals (1451, 1701, and 1217 on
    /// older servers), so the alert can point at "Ignore foreign keys".
    public static func isForeignKeyError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("foreign key constraint") || lower.contains("referenced in a foreign key")
    }
}

/// One object an Empty or Delete could not change, with the server's message.
public struct TableEditProblem: Sendable, Equatable, Hashable {
    public var name: String
    public var message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }
}

extension DatabaseClient {
    public func rename(table name: String, to newName: String, in database: String) async throws {
        if dialect.engine == .sqlite, let view = try await sqliteViewSQL(name) {
            try await renameSQLiteView(name, create: view, to: newName)
            return
        }
        _ = try await run(TableEdit.renameSQL(name, to: newName, in: database, engine: dialect.engine))
    }

    /// Duplicate Table: the source's CREATE TABLE under the new name, then its
    /// rows (generated columns left to the server). If the rows fail, the copy goes.
    public func duplicate(table name: String, to newName: String, in database: String, withRows: Bool) async throws {
        if dialect.engine == .sqlite { return try await sqliteDuplicate(table: name, to: newName, withRows: withRows) }
        await acquire()
        defer { release() }
        let show = try await perform("SHOW CREATE TABLE " + SQLQuote.qualified(database, name))
        guard let index = show.columns.firstIndex(where: { $0.name.hasPrefix("Create") }),
              let create = show.rows.first?[index].plainText else {
            throw DatabaseError(message: "The table “\(name)” no longer exists.")
        }
        _ = try await perform(TableEdit.copyCreateSQL(create, to: newName, in: database, withRows: withRows))
        guard withRows else { return }
        do {
            let columns = try await perform(
                "SELECT COLUMN_NAME AS c, EXTRA AS x FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = "
                    + SQLQuote.mysqlLiteral(database) + " AND TABLE_NAME = " + SQLQuote.mysqlLiteral(name)
                    + " ORDER BY ORDINAL_POSITION")
            let names = columns.rows.indices.compactMap { row -> String? in
                guard let column = columns.string(row, "c"),
                      !DatabaseTransfer.isGenerated(extra: columns.string(row, "x") ?? "") else { return nil }
                return column
            }
            if !names.isEmpty {
                let list = names.map(SQLQuote.identifier).joined(separator: ", ")
                _ = try await perform("INSERT INTO \(SQLQuote.qualified(database, newName)) (\(list)) SELECT \(list) FROM "
                    + SQLQuote.qualified(database, name))
            }
        } catch {
            _ = try? await perform("DROP TABLE " + SQLQuote.qualified(database, newName))
            throw DatabaseError.from(error)
        }
    }

    /// Empty Table: TRUNCATE each table. Returns the tables that failed.
    public func empty(tables: [String], in database: String, ignoringForeignKeys: Bool) async -> [TableEditProblem] {
        await withForeignKeyChecks(off: ignoringForeignKeys) {
            var problems: [TableEditProblem] = []
            for table in tables {
                do {
                    _ = try await perform(TableEdit.emptySQL(table, in: database, engine: dialect.engine))
                } catch {
                    problems.append(TableEditProblem(name: table, message: DatabaseError.from(error).message))
                }
            }
            return problems
        }
    }

    /// Delete Table: DROP TABLE for the tables, DROP VIEW for the views, a DROP
    /// for each routine. Returns a problem per statement that failed.
    public func delete(_ objects: [DBObject], in database: String, ignoringForeignKeys: Bool) async -> [TableEditProblem] {
        await withForeignKeyChecks(off: ignoringForeignKeys) {
            var problems: [TableEditProblem] = []
            let sqlite = dialect.engine == .sqlite
            let groups = sqlite ? objects.map { [$0] } : [objects.filter { $0.kind == .table }, objects.filter { $0.kind == .view }]
                + objects.filter { !$0.kind.hasRows }.map { [$0] }
            for group in groups {
                guard let sql = TableEdit.deleteSQL(group, in: database, engine: dialect.engine).first else { continue }
                do {
                    _ = try await perform(sql)
                } catch {
                    problems.append(TableEditProblem(name: group.map(\.name).joined(separator: ", "),
                                                     message: DatabaseError.from(error).message))
                }
            }
            return problems
        }
    }

    /// Holds the connection for `body`, with foreign_key_checks off for it
    /// when asked, and back as it was afterwards.
    private func withForeignKeyChecks<T: Sendable>(off: Bool, _ body: () async -> T) async -> T {
        await acquire()
        defer { release() }
        if dialect.engine == .sqlite {
            // PRAGMA foreign_keys, which Quarry keeps on for a file (S-069).
            if off { _ = try? await perform("PRAGMA foreign_keys = OFF") }
            let result = await body()
            if off { _ = try? await perform("PRAGMA foreign_keys = ON") }
            return result
        }
        if off { _ = try? await perform("SET @quarry_fk_checks = @@foreign_key_checks, foreign_key_checks = 0") }
        let result = await body()
        if off { _ = try? await perform("SET foreign_key_checks = @quarry_fk_checks") }
        return result
    }
}
