import Foundation

/// Structure changes on a SQLite file (S-070): ALTER TABLE where SQLite has it,
/// otherwise a table rebuild, always in one transaction that rolls back on any error.
extension DatabaseClient {
    /// The table's CREATE TABLE, read into its parts.
    public func sqliteTable(_ name: String) async throws -> SQLiteTable {
        let sql = try await run("SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = "
            + SQLQuote.literal(name, engine: .sqlite)).rows.first?.first?.plainText ?? ""
        guard let table = SQLiteTable(sql: sql) else {
            throw DatabaseError(message: "Quarry can’t read the CREATE TABLE of “\(name)”.")
        }
        return table
    }

    /// Runs `plan` in one transaction. Foreign keys are off while the old table goes
    /// (so DROP TABLE cascades nothing), then PRAGMA foreign_key_check must find no row
    /// of this table, or one pointing at it, without its parent; otherwise everything rolls back.
    public func applySQLite(_ plan: SQLiteChangePlan) async throws {
        await acquire()
        defer { release() }
        let keysOn = try await perform("PRAGMA foreign_keys", countingRows: false).rows.first?.first?.plainText == "1"
        if keysOn { _ = try await perform("PRAGMA foreign_keys = OFF", countingRows: false) }
        do {
            _ = try await perform("BEGIN", countingRows: false)
            if plan.needsRebuild {
                let table = SQLQuote.literal(plan.table, engine: .sqlite)
                let steps = plan.statements
                for step in steps { _ = try await perform(step, countingRows: false) }
                // Indexes and triggers go with the old table; the rebuild puts them back (read after a RENAME COLUMN).
                let others = try await perform("SELECT sql FROM sqlite_schema WHERE tbl_name = \(table) "
                    + "AND type IN ('index', 'trigger') AND sql IS NOT NULL ORDER BY type = 'trigger', name", countingRows: false)
                for step in plan.script.dropFirst(steps.count) { _ = try await perform(step, countingRows: false) }
                for row in others.rows { if let sql = row.first?.plainText { _ = try await perform(sql, countingRows: false) } }
            } else {
                for step in plan.statements { _ = try await perform(step, countingRows: false) }
            }
            if keysOn { try await checkForeignKeys(of: plan.table) }
            _ = try await perform("COMMIT", countingRows: false)
        } catch {
            _ = try? await perform("ROLLBACK", countingRows: false)
            _ = try? await perform("PRAGMA legacy_alter_table = OFF", countingRows: false)
            if keysOn { _ = try? await perform("PRAGMA foreign_keys = ON", countingRows: false) }
            var failure = DatabaseError.from(error)
            failure.message = failure.message.replacingOccurrences(of: plan.temporaryName, with: plan.table)
            throw failure
        }
        if keysOn { _ = try await perform("PRAGMA foreign_keys = ON", countingRows: false) }
    }

    /// Throws when a row of `table`, or a row pointing at it, has no parent.
    private func checkForeignKeys(of table: String) async throws {
        let name = SQLQuote.literal(table, engine: .sqlite)
        let found = try await perform("SELECT \"table\", parent FROM pragma_foreign_key_check WHERE \"table\" = \(name) "
            + "OR parent = \(name) LIMIT 1", countingRows: false)
        guard found.rows.first != nil else { return }
        let child = found.string(0, "table") ?? table
        let parent = found.string(0, "parent") ?? table
        throw DatabaseError(message: "Rows in “\(child)” would point at rows “\(parent)” doesn’t have.",
                            suggestion: "Nothing changed. Fix those rows first, or change the foreign key.")
    }

    // MARK: Views

    /// A view's CREATE VIEW, or nil when `name` is no view.
    func sqliteViewSQL(_ name: String) async throws -> String? {
        try await run("SELECT sql FROM sqlite_schema WHERE type = 'view' AND name = " + SQLQuote.literal(name, engine: .sqlite))
            .rows.first?.first?.plainText
    }

    /// SQLite's ALTER TABLE can't rename a view: a new one with the same SELECT, then the old one goes, in one transaction.
    func renameSQLiteView(_ name: String, create: String, to newName: String) async throws {
        guard let select = DefinitionChange.viewSelect(inCreate: create) else {
            throw DatabaseError(message: "Quarry can’t read the view “\(name)”.")
        }
        await acquire()
        defer { release() }
        _ = try await perform("BEGIN", countingRows: false)
        do {
            _ = try await perform(DefinitionChange.sqliteCreateSQL(
                ViewDefinition(name: newName, algorithm: .undefined, security: .definer, checkOption: .none, select: select)),
                countingRows: false)
            _ = try await perform("DROP VIEW " + SQLiteTable.quote(name), countingRows: false)
            _ = try await perform("COMMIT", countingRows: false)
        } catch {
            _ = try? await perform("ROLLBACK", countingRows: false)
            throw DatabaseError.from(error)
        }
    }

    // MARK: Tables (S-022 on SQLite)

    /// Duplicate Table on a file: the CREATE TABLE under the new name, its indexes under new names, then its rows.
    func sqliteDuplicate(table name: String, to newName: String, withRows: Bool) async throws {
        let table = try await sqliteTable(name)
        await acquire()
        defer { release() }
        let source = SQLQuote.literal(name, engine: .sqlite)
        let indexes = try await perform("SELECT name, sql FROM sqlite_schema WHERE tbl_name = \(source) AND type = 'index' "
            + "AND sql IS NOT NULL ORDER BY name", countingRows: false)
        _ = try await perform("BEGIN", countingRows: false)
        do {
            _ = try await perform(table.createSQL(named: newName), countingRows: false)
            for row in indexes.rows.indices {
                guard let index = indexes.string(row, "name"), let sql = indexes.string(row, "sql") else { continue }
                _ = try await perform(Self.copiedIndexSQL(sql, index: index, from: name, to: newName), countingRows: false)
            }
            if withRows {
                let columns = table.columns.filter { !$0.isGenerated }.map { SQLiteTable.quote($0.name) }.joined(separator: ", ")
                _ = try await perform("INSERT INTO \(SQLiteTable.quote(newName)) (\(columns)) SELECT \(columns) FROM "
                    + SQLiteTable.quote(name), countingRows: false)
            }
            _ = try await perform("COMMIT", countingRows: false)
        } catch {
            _ = try? await perform("ROLLBACK", countingRows: false)
            throw DatabaseError.from(error)
        }
    }

    /// An index's CREATE INDEX for a copy of its table: "orders_status" becomes "orders_copy_status",
    /// a name without the table's gets "_copy"; ON names the copy.
    public static func copiedIndexSQL(_ sql: String, index: String, from table: String, to copy: String) -> String {
        let newIndex = index.range(of: table, options: .caseInsensitive).map { index.replacingCharacters(in: $0, with: copy) }
            ?? index + "_" + copy
        let tokens = SQLiteTokens(sql).tokens
        guard let on = tokens.firstIndex(where: { $0.upper == "ON" }), on + 1 < tokens.count,
              let nameAt = tokens[..<on].lastIndex(where: { $0.kind == .word || $0.kind == .quoted }) else { return sql }
        var text = sql
        text.replaceSubrange(tokens[on + 1].range, with: SQLiteTable.quote(copy))
        text.replaceSubrange(tokens[nameAt].range, with: SQLiteTable.quote(newIndex))
        return text
    }
}
