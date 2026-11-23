import Foundation

/// One object in an export and what to write for it (S-041).
public struct ExportItem: Sendable, Hashable {
    public var object: DBObject
    public var part: SQLDump.Part

    public init(object: DBObject, part: SQLDump.Part) {
        self.object = object
        self.part = part
    }
}

/// What a running export is doing, for the sheet's progress bar.
public struct ExportProgress: Sendable, Equatable {
    /// "Writing rows of events", "Writing view order_totals".
    public var text: String
    /// Objects finished, of `total`.
    public var done: Int
    public var total: Int
    /// Rows written of the current table, and how many it has.
    public var rows: Int
    public var tableRows: Int
    public var bytes: Int

    public init(text: String, done: Int, total: Int, rows: Int = 0, tableRows: Int = 0, bytes: Int = 0) {
        self.text = text
        self.done = done
        self.total = total
        self.rows = rows
        self.tableRows = tableRows
        self.bytes = bytes
    }

    /// 0…1 across objects, with the current table's rows counting toward the next one.
    public var fraction: Double {
        guard total > 0 else { return 0 }
        let partial = tableRows > 0 ? min(1, Double(rows) / Double(tableRows)) : 0
        return min(1, (Double(done) + partial) / Double(total))
    }
}

extension DatabaseClient {
    /// Rows per SELECT while exporting: big enough to be quick, small enough to stay light.
    public static let exportPageSize = 5_000

    /// Writes `items` from `database` to `file` as SQL, in one consistent
    /// snapshot: tables (structure, rows, triggers), then views in dependency
    /// order, then routines. Run it on a `secondConnection()`. Cancelling the
    /// task stops it between pages; the caller discards the file.
    public func exportSQL(_ items: [ExportItem], from database: String, options: SQLDump.Options, to file: DumpFile,
                          progress: @Sendable (ExportProgress) -> Void) async throws {
        try await exportSQL(items, from: database, options: options, to: ExportOutput(file: file), progress: progress)
    }

    /// As above, to one file or a file per item (S-043). Each file of a
    /// per-item export has its own header and footer and loads on its own;
    /// all of them are one snapshot.
    public func exportSQL(_ items: [ExportItem], from database: String, options: SQLDump.Options, to output: ExportOutput,
                          progress: @Sendable (ExportProgress) -> Void) async throws {
        if dialect.engine == .sqlite {
            return try await exportSQLite(items, from: database, options: options, to: output, progress: progress)
        }
        try await use(database)
        for statement in dialect.snapshotBeginSQL { _ = try await run(statement) }
        _ = try await run("SET TIME_ZONE='+00:00'")

        let items = items.filter { !$0.part.isEmpty }
        let host = details.driverConfiguration.socketPath ?? details.driverConfiguration.host
        let header = SQLDump.header(server: serverDescription, host: host, database: database, date: .now)
        if !output.isPerTable { try output.file(for: database).write(header) }
        var done = 0
        let total = items.count
        func report(_ text: String, rows: Int = 0, tableRows: Int = 0) {
            progress(ExportProgress(text: text, done: done, total: total, rows: rows, tableRows: tableRows,
                                    bytes: output.bytesWritten))
        }
        /// The item's file: a new one with its header in a per-item export.
        func open(_ name: String) throws -> DumpFile {
            let file = try output.file(for: name)
            if output.isPerTable { try file.write(header) }
            return file
        }
        /// A per-item file is finished and closed with its item.
        func finish(_ file: DumpFile) throws {
            guard output.isPerTable else { return }
            try file.write(SQLDump.footer)
            try file.close()
        }

        for item in items where item.object.kind == .table {
            try Task.checkCancellation()
            let table = item.object.name
            report("Writing table \(table)")
            let file = try open(table)
            try file.write(SQLDump.section(.table, table))
            if item.part.structure || item.part.drop {
                let create = item.part.structure ? try await requiredCreate(item.object, in: database) : ""
                try file.write(SQLDump.structure(item.object, createStatement: create, part: item.part, options: options))
            }
            if item.part.content {
                try await exportRows(of: table, in: database, options: options, to: file) { rows, count in
                    report("Writing rows of \(table)", rows: rows, tableRows: count)
                }
            }
            if item.part.structure {
                let triggers = try await self.triggers(of: table, in: database)
                var statements: [String] = []
                for row in triggers.rows.indices {
                    guard let name = triggers.string(row, "Trigger") else { continue }
                    let create = try await run("SHOW CREATE TRIGGER " + SQLQuote.qualified(database, name))
                    if let statement = create.string(0, "SQL Original Statement") {
                        statements.append(SQLDump.unqualified(statement, database: database))
                    }
                }
                try file.write(SQLDump.triggers(statements))
            }
            try finish(file)
            done += 1
        }

        let views = items.filter { $0.object.kind == .view }
        var viewStatements: [String: String] = [:]
        for item in views where item.part.structure {
            viewStatements[item.object.name] = SQLDump.unqualified(try await requiredCreate(item.object, in: database),
                                                                   database: database)
        }
        let order = SQLDump.viewOrder(viewStatements)
        let orderedViews = views.sorted {
            (order.firstIndex(of: $0.object.name) ?? -1) < (order.firstIndex(of: $1.object.name) ?? -1)
        }
        for item in orderedViews {
            try Task.checkCancellation()
            report("Writing view \(item.object.name)")
            let file = try open(item.object.name)
            try file.write(SQLDump.section(.view, item.object.name))
            try file.write(SQLDump.structure(item.object, createStatement: viewStatements[item.object.name] ?? "",
                                             part: item.part, options: options))
            try finish(file)
            done += 1
        }

        for item in items where item.object.kind == .procedure || item.object.kind == .function {
            try Task.checkCancellation()
            report("Writing \(CreateScript.noun(item.object.kind)) \(item.object.name)")
            let create = item.part.structure
                ? SQLDump.unqualified(try await requiredCreate(item.object, in: database), database: database) : ""
            let file = try open(item.object.name)
            try file.write(SQLDump.section(item.object.kind, item.object.name))
            try file.write(SQLDump.routine(item.object, createStatement: create, part: item.part))
            try finish(file)
            done += 1
        }

        if !output.isPerTable { try output.file(for: database).write(SQLDump.footer) }
        _ = try await run("COMMIT")
        report("Done")
    }

    func requiredCreate(_ object: DBObject, in database: String) async throws -> String {
        let statement = try await createStatement(of: object, in: database)
        guard !statement.isEmpty else {
            throw DatabaseError(message: "The server didn’t give the create statement for \u{201C}\(object.name)\u{201D}. "
                + "Ask an administrator for permission to see it.")
        }
        return statement
    }

    /// A table's rows, page by page in primary-key order, as INSERTs.
    /// Generated columns are left out: the server computes them.
    private func exportRows(of table: String, in database: String, options: SQLDump.Options, to file: DumpFile,
                            progress: (Int, Int) -> Void) async throws {
        let fields = try await fields(of: table, in: database)
        let columns = fields.filter { !DatabaseTransfer.isGenerated(extra: $0.extra) }.map(\.name)
        guard !columns.isEmpty else { return }
        let keys = fields.filter { $0.key == "PRI" }.map(\.name)
        let count = try await rowCount(of: table, in: database)
        guard count > 0 else { return }
        var sql = "SELECT " + columns.map(SQLQuote.identifier).joined(separator: ", ")
            + " FROM " + SQLQuote.qualified(database, table)
        if !keys.isEmpty { sql += " ORDER BY " + keys.map(SQLQuote.identifier).joined(separator: ", ") }

        try file.write(SQLDump.rowsStart(table))
        var inserts: SQLDump.Inserts?
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await run(sql + " LIMIT \(Self.exportPageSize) OFFSET \(offset)")
            if page.rows.isEmpty { break }
            if inserts == nil {
                inserts = SQLDump.Inserts(table: table, columns: page.columns, batch: options.batch, hexBlobs: options.hexBlobs)
            }
            try file.write(inserts!.append(page.rows))
            offset += page.rows.count
            progress(offset, count)
            if page.rows.count < Self.exportPageSize { break }
        }
        if var inserts { try file.write(inserts.finish()) }
        try file.write(SQLDump.rowsEnd(table))
    }
}

extension DatabaseClient {
    /// Runs every statement of a script held in memory, stopping at the first
    /// error, in `database`. The self-test and tests load exports with it;
    /// S-044's import streams files instead.
    public func runScript(_ sql: String, in database: String) async throws {
        try await use(database)
        for statement in StatementSplitter.split(sql) where !statement.text.isEmpty {
            _ = try await run(statement.text)
        }
    }

    /// Row count and CHECKSUM TABLE for each table, to compare an export's import with its source.
    public func fingerprint(of tables: [String], in database: String) async throws -> [String: String] {
        var result: [String: String] = [:]
        for table in tables {
            let count = try await rowCount(of: table, in: database)
            let sum = try await run("CHECKSUM TABLE " + SQLQuote.qualified(database, table)).string(0, "Checksum") ?? "?"
            result[table] = "\(count) rows, checksum \(sum)"
        }
        return result
    }
}

/// One table's rows for a CSV, JSON or XML export (S-042): a whole table, or
/// Content's rows under its filter and sort.
public struct DataSource: Sendable, Hashable {
    public var table: String
    /// A WHERE clause without the keyword, as Content applied it.
    public var condition: String?
    public var orderBy: String?
    public var ascending: Bool

    public init(table: String, condition: String? = nil, orderBy: String? = nil, ascending: Bool = true) {
        self.table = table
        self.condition = condition
        self.orderBy = orderBy
        self.ascending = ascending
    }

    /// The SELECT that reads the rows, without LIMIT. The sort column first,
    /// then the primary key, so pages never skip or repeat a row.
    public func select(in database: String, keys: [String]) -> String {
        var sql = "SELECT * FROM " + SQLQuote.qualified(database, table)
        if let condition, !condition.isEmpty { sql += " WHERE " + condition }
        var order: [String] = []
        if let orderBy { order.append(SQLQuote.identifier(orderBy) + (ascending ? "" : " DESC")) }
        order += keys.filter { $0 != orderBy }.map(SQLQuote.identifier)
        if !order.isEmpty { sql += " ORDER BY " + order.joined(separator: ", ") }
        return sql
    }
}

extension DatabaseClient {
    /// Writes `sources` from `database` to `file` as CSV, JSON or XML, in one
    /// consistent snapshot, page by page. Run it on a `secondConnection()`;
    /// cancelling stops it between pages and the caller discards the file.
    /// Returns how many rows it wrote.
    @discardableResult
    public func exportData(_ sources: [DataSource], from database: String, writer: DataExport.Writer, to file: DumpFile,
                           progress: @Sendable (ExportProgress) -> Void) async throws -> Int {
        try await exportData(sources, from: database, writer: writer, to: ExportOutput(file: file), progress: progress)
    }

    /// As above, to one file or a file per table (S-043); each file of a
    /// per-table export is whole on its own (its own JSON object, XML root).
    @discardableResult
    public func exportData(_ sources: [DataSource], from database: String, writer: DataExport.Writer, to output: ExportOutput,
                           progress: @Sendable (ExportProgress) -> Void) async throws -> Int {
        try await use(database)
        for statement in dialect.snapshotBeginSQL { _ = try await run(statement) }
        var writer = writer
        var total = 0
        if !output.isPerTable { try output.file(for: database).write(writer.start()) }
        for (done, source) in sources.enumerated() {
            try Task.checkCancellation()
            let table = source.table
            let file = try output.file(for: table)
            if output.isPerTable { try file.write(writer.start()) }
            progress(ExportProgress(text: "Writing rows of \(table)", done: done, total: sources.count, bytes: output.bytesWritten))
            let fields = try await fields(of: table, in: database)
            let count = try await rowCount(of: table, in: database, where: source.condition)
            let sql = source.select(in: database, keys: fields.filter { $0.key == "PRI" }.map(\.name))
            var offset = 0
            var begun = false
            while true {
                try Task.checkCancellation()
                let page = try await run(sql + " LIMIT \(Self.exportPageSize) OFFSET \(offset)")
                if !begun {
                    // An empty table still gets its column names, from SHOW FULL COLUMNS.
                    let columns = page.columns.isEmpty ? fields.map { ResultColumn(name: $0.name) } : page.columns
                    try file.write(writer.begin(table, columns: columns))
                    begun = true
                }
                try file.write(writer.append(page.rows))
                offset += page.rows.count
                total += page.rows.count
                progress(ExportProgress(text: "Writing rows of \(table)", done: done, total: sources.count,
                                        rows: offset, tableRows: count, bytes: output.bytesWritten))
                if page.rows.count < Self.exportPageSize { break }
            }
            try file.write(writer.end())
            if output.isPerTable {
                try file.write(writer.finish())
                try file.close()
            }
        }
        if !output.isPerTable { try output.file(for: database).write(writer.finish()) }
        _ = try await run("COMMIT")
        progress(ExportProgress(text: "Done", done: sources.count, total: sources.count, bytes: output.bytesWritten))
        return total
    }
}
