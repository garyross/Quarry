import Foundation

/// A database's default character set and collation, from information_schema.SCHEMATA.
public struct DatabaseOptions: Sendable, Equatable {
    public var charset: String
    public var collation: String

    public init(charset: String, collation: String) {
        self.charset = charset
        self.collation = collation
    }
}

/// Change Character Set (S-019): ALTER DATABASE with a character set and an
/// optional collation. Without one, the server gives the character set's default.
public struct AlterDatabase: Sendable, Equatable {
    public var name: String
    public var charset: String
    public var collation: String?

    public init(name: String, charset: String, collation: String? = nil) {
        self.name = name
        self.charset = charset
        self.collation = collation
    }

    public var sql: String {
        var sql = "ALTER DATABASE " + SQLQuote.identifier(name) + " CHARACTER SET " + SQLQuote.identifier(charset)
        if let collation { sql += " COLLATE " + SQLQuote.identifier(collation) }
        return sql
    }
}

/// Rules for Rename Database and Duplicate Database (S-019). MariaDB and
/// MySQL have no RENAME DATABASE, so both make a new database and fill it.
public enum DatabaseTransfer {
    /// Databases the server owns: they cannot be renamed, changed or deleted.
    public static let systemDatabases: Set<String> = ["information_schema", "performance_schema", "mysql", "sys"]

    public static func isSystem(_ name: String) -> Bool { systemDatabases.contains(name.lowercased()) }

    /// A definition from SHOW CREATE, pointed at `target`: every "`source`."
    /// becomes "`target`.". Views always name their tables this way; routines
    /// and triggers do when their author did. Run it after USE `target`, so
    /// unqualified names land there too.
    public static func retarget(_ sql: String, from source: String, to target: String) -> String {
        sql.replacingOccurrences(of: SQLQuote.identifier(source) + ".", with: SQLQuote.identifier(target) + ".")
    }

    /// A CREATE TABLE for a copy without rows: the table options lose
    /// AUTO_INCREMENT=n, so the empty copy counts from 1.
    public static func withoutAutoIncrement(_ createTable: String) -> String {
        // The options follow the last closing parenthesis of the column list.
        guard let close = createTable.lastIndex(of: ")") else { return createTable }
        let options = String(createTable[close...])
            .replacingOccurrences(of: #" AUTO_INCREMENT=\d+"#, with: "", options: .regularExpression)
        return String(createTable[..<close]) + options
    }

    /// One RENAME TABLE for every table, so they move together or not at all.
    public static func renameTablesSQL(_ tables: [String], from source: String, to target: String) -> String {
        "RENAME TABLE " + tables.map {
            SQLQuote.qualified(source, $0) + " TO " + SQLQuote.qualified(target, $0)
        }.joined(separator: ", ")
    }

    /// Copies rows into the new table. Generated columns are left out: the
    /// server computes them and refuses a value.
    public static func copyRowsSQL(table: String, columns: [String], from source: String, to target: String) -> String {
        let list = columns.map(SQLQuote.identifier).joined(separator: ", ")
        return "INSERT INTO \(SQLQuote.qualified(target, table)) (\(list)) SELECT \(list) FROM \(SQLQuote.qualified(source, table))"
    }

    /// True for a column the server computes (EXTRA from information_schema.COLUMNS).
    public static func isGenerated(extra: String) -> Bool {
        let extra = extra.uppercased()
        return extra.contains("GENERATED") || extra.contains("VIRTUAL") || extra.contains("PERSISTENT")
            || extra.contains("STORED")
    }
}

/// What a running rename or duplicate is doing, for the sheet's progress line.
public struct TransferProgress: Sendable, Equatable {
    public var text: String
    public var done: Int
    public var total: Int

    public init(text: String, done: Int, total: Int) {
        self.text = text
        self.done = done
        self.total = total
    }
}

/// How a rename or duplicate ended. Problems name each object that failed;
/// the job itself went through.
public struct TransferReport: Sendable, Equatable {
    public var problems: [String] = []
    /// Rename only: the old database was empty at the end and was deleted.
    public var droppedSource = false

    public init(problems: [String] = [], droppedSource: Bool = false) {
        self.problems = problems
        self.droppedSource = droppedSource
    }
}

/// Everything in a database that a rename or duplicate carries, read before
/// anything changes, so a read error changes nothing.
struct DatabaseContents {
    struct Table { var name: String; var create: String; var columns: [String] }
    struct Definition { var name: String; var kind: String; var create: String }

    var options: DatabaseOptions
    var tables: [Table] = []
    var views: [Definition] = []
    var triggers: [Definition] = []
    var routines: [Definition] = []
    var events: [String] = []
}

extension DatabaseClient {
    public func options(of database: String) async throws -> DatabaseOptions {
        let result = try await run(
            "SELECT DEFAULT_CHARACTER_SET_NAME AS cs, DEFAULT_COLLATION_NAME AS co FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = "
                + SQLQuote.mysqlLiteral(database))
        guard let charset = result.string(0, "cs") else {
            throw DatabaseError(message: "The database “\(database)” no longer exists.")
        }
        return DatabaseOptions(charset: charset, collation: result.string(0, "co") ?? "")
    }

    public func alter(_ database: AlterDatabase) async throws {
        _ = try await run(database.sql)
    }

    public func drop(database: String) async throws {
        _ = try await run("DROP DATABASE " + SQLQuote.identifier(database))
    }

    /// Duplicate Database: a new database with the source's character set and
    /// collation, its tables (and rows), views, triggers and routines.
    /// A table that fails stops the copy and deletes the half-made database;
    /// a view, trigger or routine that fails is listed in the report.
    public func duplicate(_ source: String, to target: String, withRows: Bool,
                          progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferReport {
        await acquire()
        defer { release() }
        let contents = try await readContents(of: source)
        _ = try await perform(NewDatabase(name: target, charset: contents.options.charset,
                                      collation: contents.options.collation).sql)
        _ = try await perform("SET @quarry_fk_checks = @@foreign_key_checks, foreign_key_checks = 0")
        var report = TransferReport()
        let total = contents.tables.count + contents.views.count + contents.triggers.count + contents.routines.count
        var done = 0
        do {
            _ = try await perform("USE " + SQLQuote.identifier(target))
            for table in contents.tables {
                progress(TransferProgress(text: "Copying \(table.name)", done: done, total: total))
                let create = withRows ? table.create : DatabaseTransfer.withoutAutoIncrement(table.create)
                _ = try await perform(create)
                if withRows, !table.columns.isEmpty {
                    _ = try await perform(DatabaseTransfer.copyRowsSQL(table: table.name, columns: table.columns,
                                                                        from: source, to: target))
                }
                done += 1
            }
        } catch {
            _ = try? await perform("SET foreign_key_checks = @quarry_fk_checks")
            _ = try? await perform("USE " + SQLQuote.identifier(source))
            _ = try? await perform("DROP DATABASE " + SQLQuote.identifier(target))
            throw DatabaseError.from(error)
        }
        report.problems += await createViews(contents.views, from: source, to: target, done: &done, total: total,
                                             progress: progress).problems
        for definition in contents.triggers + contents.routines {
            progress(TransferProgress(text: "Copying \(definition.name)", done: done, total: total))
            do {
                _ = try await perform(DatabaseTransfer.retarget(definition.create, from: source, to: target))
            } catch {
                report.problems.append("\(definition.kind) “\(definition.name)”: \(DatabaseError.from(error).message)")
            }
            done += 1
        }
        if !contents.events.isEmpty {
            report.problems.append("Events aren’t copied, so they don’t run twice: "
                + contents.events.joined(separator: ", ") + ".")
        }
        _ = try? await perform("SET foreign_key_checks = @quarry_fk_checks")
        return report
    }

    /// Rename Database: makes `target` with the source's character set and
    /// collation and moves everything into it. Routines are copied and tables
    /// moved first; if either fails, the triggers come back and `target` is
    /// deleted, so nothing changed. Then views and triggers are made again
    /// in `target`, events move, and the source is deleted once it is empty.
    public func rename(_ source: String, to target: String,
                       progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferReport {
        await acquire()
        defer { release() }
        let contents = try await readContents(of: source)
        _ = try await perform(NewDatabase(name: target, charset: contents.options.charset,
                                      collation: contents.options.collation).sql)
        var report = TransferReport()
        let total = contents.routines.count + contents.tables.count + contents.triggers.count + contents.views.count
            + contents.events.count
        var done = 0
        var droppedTriggers: [DatabaseContents.Definition] = []
        do {
            _ = try await perform("USE " + SQLQuote.identifier(target))
            for routine in contents.routines {
                progress(TransferProgress(text: "Moving \(routine.name)", done: done, total: total))
                _ = try await perform(DatabaseTransfer.retarget(routine.create, from: source, to: target))
                done += 1
            }
            // A table with triggers cannot move to another database, so they go first.
            for trigger in contents.triggers {
                _ = try await perform("DROP TRIGGER " + SQLQuote.qualified(source, trigger.name))
                droppedTriggers.append(trigger)
            }
            if !contents.tables.isEmpty {
                progress(TransferProgress(text: "Moving \(contents.tables.count) tables", done: done, total: total))
                _ = try await perform(DatabaseTransfer.renameTablesSQL(contents.tables.map(\.name), from: source, to: target))
                done += contents.tables.count
            }
        } catch {
            _ = try? await perform("USE " + SQLQuote.identifier(source))
            for trigger in droppedTriggers { _ = try? await perform(trigger.create) }
            _ = try? await perform("DROP DATABASE " + SQLQuote.identifier(target))
            throw DatabaseError.from(error)
        }
        for trigger in contents.triggers {
            progress(TransferProgress(text: "Moving \(trigger.name)", done: done, total: total))
            do {
                _ = try await perform(DatabaseTransfer.retarget(trigger.create, from: source, to: target))
            } catch {
                report.problems.append("Trigger “\(trigger.name)”: \(DatabaseError.from(error).message)")
            }
            done += 1
        }
        let views = await createViews(contents.views, from: source, to: target, done: &done, total: total,
                                      progress: progress)
        report.problems += views.problems
        for view in contents.views where views.made.contains(view.name) {
            _ = try? await perform("DROP VIEW " + SQLQuote.qualified(source, view.name))
        }
        for event in contents.events {
            progress(TransferProgress(text: "Moving \(event)", done: done, total: total))
            do {
                _ = try await perform("ALTER EVENT \(SQLQuote.qualified(source, event)) RENAME TO \(SQLQuote.qualified(target, event))")
            } catch {
                report.problems.append("Event “\(event)”: \(DatabaseError.from(error).message)")
            }
            done += 1
        }
        for routine in contents.routines {
            _ = try? await perform("DROP \(routine.kind.uppercased()) \(SQLQuote.qualified(source, routine.name))")
        }
        let left = (try? await perform("SHOW FULL TABLES FROM " + SQLQuote.identifier(source)).rows.count) ?? 1
        let leftRoutines = (try? await perform(
            "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = " + SQLQuote.mysqlLiteral(source))
            .rows.first?.first?.plainText.flatMap(Int.init)) ?? 1
        let leftEvents = (try? await perform(
            "SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA = " + SQLQuote.mysqlLiteral(source))
            .rows.first?.first?.plainText.flatMap(Int.init)) ?? 1
        if left + leftRoutines + leftEvents == 0 {
            if (try? await perform("DROP DATABASE " + SQLQuote.identifier(source))) != nil { report.droppedSource = true }
        }
        if !report.droppedSource {
            report.problems.append("“\(source)” was kept, because it still holds objects that didn’t move.")
        }
        return report
    }

    /// Views can use other views, so each round makes those whose views exist,
    /// until a round makes none. Returns the views made and one problem per view left.
    private func createViews(_ views: [DatabaseContents.Definition], from source: String, to target: String,
                             done: inout Int, total: Int,
                             progress: @Sendable (TransferProgress) -> Void) async -> (made: Set<String>, problems: [String]) {
        var pending = views
        var made: Set<String> = []
        var errors: [String: String] = [:]
        while !pending.isEmpty {
            var left: [DatabaseContents.Definition] = []
            for view in pending {
                progress(TransferProgress(text: "Making view \(view.name)", done: done, total: total))
                do {
                    _ = try await perform(DatabaseTransfer.retarget(view.create, from: source, to: target))
                    made.insert(view.name)
                    done += 1
                } catch {
                    errors[view.name] = DatabaseError.from(error).message
                    left.append(view)
                }
            }
            if left.count == pending.count { break }
            pending = left
        }
        return (made, pending.map { "View “\($0.name)”: \(errors[$0.name] ?? "")" })
    }

    private func readContents(of database: String) async throws -> DatabaseContents {
        let options = try await perform(
            "SELECT DEFAULT_CHARACTER_SET_NAME AS cs, DEFAULT_COLLATION_NAME AS co FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = "
                + SQLQuote.mysqlLiteral(database))
        guard let charset = options.string(0, "cs") else {
            throw DatabaseError(message: "The database “\(database)” no longer exists.")
        }
        var contents = DatabaseContents(options: DatabaseOptions(charset: charset, collation: options.string(0, "co") ?? ""))
        let quoted = SQLQuote.mysqlLiteral(database)

        let columns = try await perform(
            "SELECT TABLE_NAME AS t, COLUMN_NAME AS c, EXTRA AS x FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = "
                + quoted + " ORDER BY TABLE_NAME, ORDINAL_POSITION")
        var insertable: [String: [String]] = [:]
        for row in columns.rows.indices {
            guard let table = columns.string(row, "t"), let column = columns.string(row, "c") else { continue }
            if !DatabaseTransfer.isGenerated(extra: columns.string(row, "x") ?? "") {
                insertable[table, default: []].append(column)
            }
        }

        let objects = try await perform("SHOW FULL TABLES FROM " + SQLQuote.identifier(database))
        for row in objects.rows {
            guard row.count >= 2, let name = row[0].plainText, let type = row[1].plainText else { continue }
            if type == "VIEW" {
                contents.views.append(.init(name: name, kind: "View",
                                            create: try await showCreate("VIEW", database, name)))
            } else {
                contents.tables.append(.init(name: name, create: try await showCreate("TABLE", database, name),
                                             columns: insertable[name] ?? []))
            }
        }

        let triggers = try await perform(
            "SELECT TRIGGER_NAME AS n FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = " + quoted
                + " ORDER BY EVENT_OBJECT_TABLE, ACTION_ORDER")
        for row in triggers.rows.indices {
            guard let name = triggers.string(row, "n") else { continue }
            contents.triggers.append(.init(name: name, kind: "Trigger", create: try await showCreate("TRIGGER", database, name)))
        }

        let routines = try await perform(
            "SELECT ROUTINE_NAME AS n, ROUTINE_TYPE AS t FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = " + quoted
                + " ORDER BY ROUTINE_NAME")
        for row in routines.rows.indices {
            guard let name = routines.string(row, "n"), let type = routines.string(row, "t") else { continue }
            contents.routines.append(.init(name: name, kind: type.capitalized,
                                           create: try await showCreate(type.uppercased(), database, name)))
        }

        let events = try await perform(
            "SELECT EVENT_NAME AS n FROM information_schema.EVENTS WHERE EVENT_SCHEMA = " + quoted + " ORDER BY EVENT_NAME")
        contents.events = events.rows.indices.compactMap { events.string($0, "n") }
        return contents
    }

    /// The statement from SHOW CREATE (TRIGGER's is "SQL Original Statement").
    /// Without the privilege to see it, the server sends NULL; that stops the job.
    private func showCreate(_ keyword: String, _ database: String, _ name: String) async throws -> String {
        let result = try await perform("SHOW CREATE \(keyword) \(SQLQuote.qualified(database, name))")
        let index = result.columns.firstIndex { $0.name.hasPrefix("Create") || $0.name == "SQL Original Statement" }
        guard let index, let row = result.rows.first, let sql = row[index].plainText, !sql.isEmpty else {
            throw DatabaseError(message: "Quarry can’t read the definition of \(keyword.lowercased()) “\(name)”. "
                + "Ask for the privilege to see it, then try again.")
        }
        return sql
    }
}
