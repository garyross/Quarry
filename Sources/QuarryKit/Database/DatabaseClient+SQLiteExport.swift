import Foundation

extension DatabaseClient {
    /// Export as SQL from a SQLite file (S-071): a script `sqlite3` reads back.
    /// Tables (DROP, CREATE, rows, `sqlite_sequence`, indexes, triggers), then
    /// views in dependency order with their triggers, all in one read
    /// transaction. Run it on a read-only `secondConnection(readOnly: true)`.
    func exportSQLite(_ items: [ExportItem], from database: String, options: SQLDump.Options, to output: ExportOutput,
                      progress: @Sendable (ExportProgress) -> Void) async throws {
        for statement in dialect.snapshotBeginSQL { _ = try await run(statement) }

        let items = items.filter { !$0.part.isEmpty }
        let schema = dialect.identifier(database) + ".sqlite_schema"
        let header = SQLDump.SQLite.header(file: details.fileURL?.lastPathComponent ?? database,
                                           version: serverDescription, date: .now)
        if !output.isPerTable { try output.file(for: database).write(header) }
        let hasSequence = try await !run("SELECT 1 FROM \(schema) WHERE name = 'sqlite_sequence'").rows.isEmpty
        var done = 0
        let total = items.count
        func report(_ text: String, rows: Int = 0, tableRows: Int = 0) {
            progress(ExportProgress(text: text, done: done, total: total, rows: rows, tableRows: tableRows,
                                    bytes: output.bytesWritten))
        }
        func open(_ name: String) throws -> DumpFile {
            let file = try output.file(for: name)
            if output.isPerTable { try file.write(header) }
            return file
        }
        func finish(_ file: DumpFile) throws {
            guard output.isPerTable else { return }
            try file.write(SQLDump.SQLite.footer)
            try file.close()
        }
        /// The CREATE INDEX or CREATE TRIGGER statements on `name`; automatic indexes have no SQL.
        func schemaSQL(_ type: String, on name: String) async throws -> [String] {
            try await run("SELECT sql FROM \(schema) WHERE type = '\(type)' AND tbl_name = \(dialect.literal(name)) "
                + "AND sql IS NOT NULL ORDER BY name").rows.compactMap { $0.first?.plainText }
        }
        // SQLite's CREATE TABLE has no AUTO_INCREMENT=n to drop; sqlite_sequence carries the numbering.
        var structureOptions = options
        structureOptions.autoIncrement = true

        for item in items where item.object.kind == .table {
            try Task.checkCancellation()
            let table = item.object.name
            report("Writing table \(table)")
            let file = try open(table)
            try file.write(SQLDump.section(.table, table))
            if item.part.structure || item.part.drop {
                let create = item.part.structure ? try await requiredCreate(item.object, in: database) : ""
                try file.write(SQLDump.structure(item.object, createStatement: create, part: item.part, options: structureOptions))
            }
            if item.part.content {
                try await exportSQLiteRows(of: table, in: database, options: options, to: file) { rows, count in
                    report("Writing rows of \(table)", rows: rows, tableRows: count)
                }
            }
            if hasSequence, item.part.structure || item.part.content,
               let seq = try await run("SELECT seq FROM \(dialect.identifier(database)).sqlite_sequence "
                                       + "WHERE name = \(dialect.literal(table))").rows.first?.first?.plainText {
                try file.write(SQLDump.SQLite.sequence(table: table, value: seq))
            }
            if item.part.structure {
                try file.write(SQLDump.SQLite.statements(try await schemaSQL("index", on: table)
                                                         + schemaSQL("trigger", on: table)))
            }
            try finish(file)
            done += 1
        }

        let views = items.filter { $0.object.kind == .view }
        var viewStatements: [String: String] = [:]
        for item in views where item.part.structure {
            viewStatements[item.object.name] = try await requiredCreate(item.object, in: database)
        }
        let order = SQLDump.SQLite.viewOrder(viewStatements)
        let orderedViews = views.sorted {
            (order.firstIndex(of: $0.object.name) ?? -1) < (order.firstIndex(of: $1.object.name) ?? -1)
        }
        for item in orderedViews {
            try Task.checkCancellation()
            report("Writing view \(item.object.name)")
            let file = try open(item.object.name)
            try file.write(SQLDump.section(.view, item.object.name))
            try file.write(SQLDump.structure(item.object, createStatement: viewStatements[item.object.name] ?? "",
                                             part: item.part, options: structureOptions))
            if item.part.structure {
                try file.write(SQLDump.SQLite.statements(try await schemaSQL("trigger", on: item.object.name)))
            }
            try finish(file)
            done += 1
        }

        if !output.isPerTable { try output.file(for: database).write(SQLDump.SQLite.footer) }
        _ = try await run("COMMIT")
        report("Done")
    }

    /// A table's rows as INSERTs, page by page in primary-key (or rowid) order,
    /// each value written by SQLite's quote() so it comes back exactly.
    private func exportSQLiteRows(of table: String, in database: String, options: SQLDump.Options, to file: DumpFile,
                                  progress: (Int, Int) -> Void) async throws {
        let fields = try await fields(of: table, in: database)
        let columns = fields.map(\.name)
        guard !columns.isEmpty else { return }
        var keys = fields.filter { $0.key == "PRI" }.map(\.name)
        if keys.isEmpty, let rowID = SQLiteDialect.rowIDName(avoiding: columns) { keys = [rowID] }
        let count = try await rowCount(of: table, in: database)
        guard count > 0 else { return }
        let sql = SQLDump.SQLite.select(columns: columns, table: table, database: database, orderBy: keys)
        var inserts = SQLDump.Inserts(table: table, columns: columns.map { ResultColumn(name: $0) }, batch: options.batch,
                                      hexBlobs: false, literals: true)
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await run(sql + " LIMIT \(Self.exportPageSize) OFFSET \(offset)")
            if page.rows.isEmpty { break }
            try file.write(inserts.append(page.rows))
            offset += page.rows.count
            progress(offset, count)
            if page.rows.count < Self.exportPageSize { break }
        }
        try file.write(inserts.finish())
    }
}
