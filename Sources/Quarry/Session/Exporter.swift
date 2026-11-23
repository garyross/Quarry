import AppKit
import Foundation
import QuarryKit
import QuarryControllers

/// The Export sheet (S-041, S-042): the format, where the rows come from,
/// which objects and which parts of each, the options, and the running export.
/// The export runs on a connection of its own, so the window keeps browsing
/// while it writes.
@MainActor @Observable
final class Exporter: Identifiable {
    struct Row: Identifiable, Hashable {
        let object: DBObject
        var part: SQLDump.Part
        /// CSV, JSON and XML: write this table's or view's rows.
        var include: Bool
        var id: String { object.id }
        /// Only tables have rows to write; a view's Content would repeat its tables' rows.
        var hasContent: Bool { object.kind == .table }
        /// Tables and views have rows for CSV, JSON and XML; routines don't.
        var hasData: Bool { object.kind == .table || object.kind == .view }
    }

    enum Format: String, CaseIterable, Identifiable {
        case sql, csv, json, xml
        var id: String { rawValue }
        var title: String { rawValue.uppercased() }
        var data: DataExport.Format? { DataExport.Format(rawValue: rawValue) }
    }

    /// Where a CSV, JSON or XML export's rows come from.
    enum Source: String, CaseIterable, Identifiable {
        case tables, content, result
        var id: String { rawValue }
    }

    /// Content's table under its filter and sort, when Content shows one.
    struct ContentRows: Sendable {
        let database: String
        let source: DataSource
        let rows: Int
    }

    /// The Query view's results, held in memory.
    struct QueryRows: Sendable {
        let columns: [ResultColumn]
        let rows: [[CellValue]]
        let statement: String
    }

    enum BatchUnit: String, CaseIterable, Identifiable {
        case kilobytes = "KB of data"
        case rows
        var id: String { rawValue }
    }

    let database: String
    /// A SQLite file's export leaves out MySQL's options (S-071).
    let engine: Engine
    var rows: [Row]
    /// SQL writes a script; CSV, JSON and XML write rows.
    var format = Format.sql {
        didSet { if format == .sql { source = .tables } }
    }
    var source = Source.tables {
        didSet { if source != .tables, format == .sql { format = .csv } }
    }
    let content: ContentRows?
    let result: QueryRows?
    /// CSV's separator, enclosure, escape, line end, field names and NULL.
    var csv = CSVFormat()
    var autoIncrement = true
    var batchSize = 250
    var batchUnit = BatchUnit.kilobytes
    var hexBlobs = true
    var compression = SQLDump.Compression.none
    /// The file name pattern (S-043), such as `{database}_{date}`; empty uses
    /// the default name. Remembered for the next export.
    /// Tests and snapshots (a store in /tmp) neither read nor keep it.
    var namePattern = Store.isOverridden ? "" : UserDefaults.standard.string(forKey: Exporter.namePatternKey) ?? ""
    /// Write each checked item to its own file in a folder.
    var perTable = false
    /// What `{host}` and `{connection}` stand for.
    let host: String
    let connection: String

    /// The file written, once the export is done; the folder of a per-table export.
    private(set) var finishedFile: URL?
    /// Every file written, once the export is done.
    private(set) var finishedFiles: [URL] = []
    /// Rows written by a filtered content or query result export.
    private(set) var rowsWritten = 0
    /// The running export, on its own connection.
    private let job: ConnectionJob<ExportProgress>

    var progress: ExportProgress? { job.progress }
    var error: String? { job.error }
    var wasCancelled: Bool { job.wasCancelled }

    /// `objects` in sidebar order; `chosen` (ids) start checked, or all when empty.
    /// `content` and `result` are the other sources on offer; `source` and
    /// `format` start the sheet on one (the Query results' Export… starts on CSV).
    init(database: String, objects: [DBObject], chosen: Set<String>, client: DatabaseClient,
         content: ContentRows? = nil, result: QueryRows? = nil, source: Source = .tables, format: Format = .sql,
         host: String = "", connection: String = "") {
        self.database = database
        self.host = host
        self.connection = connection
        job = ConnectionJob(client: client, failurePrefix: "Couldn’t export: ", clearsProgress: true, readOnly: true)
        engine = client.dialect.engine
        self.content = content
        self.result = result
        rows = objects.map { object in
            let on = chosen.isEmpty || chosen.contains(object.id)
            return Row(object: object, part: SQLDump.Part(structure: on, content: on && object.kind == .table, drop: on),
                       include: on)
        }
        let available = (source == .content && content == nil) || (source == .result && result == nil) ? .tables : source
        self.format = available != .tables && format == .sql ? .csv : format
        self.source = available
    }

    /// The sources this sheet can export: Tables always, the others when there are rows to read.
    var sources: [Source] {
        [.tables] + (content == nil ? [] : [.content]) + (result == nil ? [] : [.result])
    }

    /// "Tables", "Content of “orders”" (with "Filtered" when a filter is on), "Query Result".
    func title(of source: Source) -> String {
        switch source {
        case .tables: "Tables"
        case .content:
            content.map { ($0.source.condition == nil ? "Content" : "Filtered Content") + " of \u{201C}\($0.source.table)\u{201D}" }
                ?? "Content"
        case .result: "Query Result"
        }
    }

    /// The line under the Source picker for rows that aren't whole tables.
    var sourceSummary: String {
        switch source {
        case .tables: ""
        case .content:
            content.map { content in
                let rows = "\(content.rows.formatted()) row\(content.rows == 1 ? "" : "s")"
                guard let condition = content.source.condition else { return rows + ", in the grid’s order" }
                return rows + " where " + condition
            } ?? ""
        case .result:
            result.map { "\($0.rows.count.formatted()) row\($0.rows.count == 1 ? "" : "s") from " + $0.statement } ?? ""
        }
    }

    /// The tables and views a CSV, JSON or XML export lists.
    var dataRows: [Row] { rows.filter(\.hasData) }

    var dataTables: [String] { dataRows.filter(\.include).map(\.object.name) }

    var title: String { "Export \u{201C}\(engine == .sqlite && !connection.isEmpty ? connection : database)\u{201D}" }

    /// What files are named after: the database, or a SQLite file's name without
    /// its extension, since every file's database is "main" (S-071).
    var baseName: String {
        guard engine == .sqlite, !connection.isEmpty else { return database }
        return (connection as NSString).deletingPathExtension
    }
    var isWorking: Bool { job.isRunning }

    var items: [ExportItem] {
        rows.map { row in
            var part = row.part
            if !row.hasContent { part.content = false }
            return ExportItem(object: row.object, part: part)
        }
        .filter { !$0.part.isEmpty }
    }

    /// Nothing to write: the line that says so, or nil.
    var nothingChecked: String? {
        switch (format, source) {
        case (.sql, _): items.isEmpty ? "Check at least one item." : nil
        case (_, .tables): dataTables.isEmpty ? "Check at least one table or view." : nil
        case (_, .content): content == nil ? "Open a table on Content first." : nil
        case (_, .result): result == nil ? "Run a query first." : nil
        }
    }

    var canExport: Bool { nothingChecked == nil && !isWorking }

    /// "9 of 12 items".
    var checkedSummary: String {
        if format == .sql { return "\(items.count) of \(rows.count) item\(rows.count == 1 ? "" : "s")" }
        let count = dataRows.count
        return "\(dataTables.count) of \(count) item\(count == 1 ? "" : "s")"
    }

    /// Auto-increment values and BLOBs as hex: a SQLite file keeps its numbering
    /// in sqlite_sequence and writes every BLOB as X'…' anyway.
    var showsServerOptions: Bool { engine == .mysql }

    var options: SQLDump.Options {
        SQLDump.Options(autoIncrement: autoIncrement,
                        batch: batchUnit == .rows ? .rows(max(1, batchSize)) : .kilobytes(max(1, batchSize)),
                        hexBlobs: hexBlobs, compression: compression)
    }

    static let namePatternKey = "exportFileNamePattern"

    /// The extension after every name: "sql", "csv.gz".
    var fileExtension: String {
        format == .sql ? compression.fileExtension : format.rawValue + (compression == .gzip ? ".gz" : "")
    }

    /// The object names a per-table export writes, one file each.
    private var splitNames: [String] { format == .sql ? items.map(\.object.name) : dataTables }

    /// One file per table is on offer: whole tables, more than one checked.
    var canSplit: Bool { source == .tables && splitNames.count > 1 }
    var splitsFiles: Bool { perTable && canSplit }

    private func values(table: String?, date: Date) -> ExportFileName.Values {
        ExportFileName.Values(database: engine == .sqlite ? baseName : content?.database ?? database, table: table, host: host,
                              connection: connection, date: date)
    }

    /// "quarry_demo.sql", "orders.csv" for one table, "Query Result.json",
    /// with ".gz" after it with Gzip; or the name pattern expanded.
    func fileName(at date: Date = .now) -> String {
        let table: String?
        let base: String
        switch (format, source) {
        case (.sql, _):
            table = items.count == 1 ? items[0].object.name : nil
            base = table ?? baseName
        case (_, .tables):
            table = dataTables.count == 1 ? dataTables[0] : nil
            base = table ?? baseName
        case (_, .content):
            table = content?.source.table
            base = table ?? baseName
        case (_, .result):
            table = nil
            base = "Query Result"
        }
        let pattern = ExportFileName(namePattern)
        let named = pattern.isEmpty ? "" : pattern.expand(values(table: table, date: date))
        let safe = named.isEmpty ? ExportFileName.safe(base) : named
        return (safe.isEmpty ? "export" : safe) + "." + fileExtension
    }

    var fileName: String { fileName() }

    /// A per-table export's file names by object name, each different.
    func perTableNames(at date: Date = .now) -> [(object: String, file: String)] {
        let pattern = ExportFileName(namePattern)
        var used: Set<String> = []
        return splitNames.map { object in
            let base = pattern.perTable(values(table: object, date: date))
            var name = (base.isEmpty ? "export" : base) + "." + fileExtension
            var number = 2
            while used.contains(name.lowercased()) {
                name = (base.isEmpty ? "export" : base) + "_\(number)." + fileExtension
                number += 1
            }
            used.insert(name.lowercased())
            return (object, name)
        }
    }

    /// The line under the name: what Export… will write.
    var namePreview: String {
        guard splitsFiles else { return fileName }
        let names = perTableNames().map(\.file)
        let shown = names.prefix(2).joined(separator: ", ")
        return "\(names.count) files: " + shown + (names.count > 2 ? ", …" : "")
    }

    /// Adds a token where the pattern ends.
    func insert(_ token: ExportFileName.Token) {
        namePattern += token.text
    }

    func setAll(_ on: Bool) {
        for index in rows.indices {
            if format == .sql {
                rows[index].part = SQLDump.Part(structure: on, content: on && rows[index].hasContent, drop: on)
            } else {
                rows[index].include = on
            }
        }
    }

    /// "Exported 9 items to quarry_demo.sql".
    var finishedText: String? {
        guard let finishedFile else { return nil }
        let name = finishedFile.lastPathComponent
        if finishedFiles.count > 1 || finishedFiles.first != finishedFile {
            let count = format == .sql ? items.count : dataTables.count
            return "Exported \(count) item\(count == 1 ? "" : "s") to \(finishedFiles.count) file\(finishedFiles.count == 1 ? "" : "s") in \(name)"
        }
        switch (format, source) {
        case (.sql, _), (_, .tables):
            let count = format == .sql ? items.count : dataTables.count
            return "Exported \(count) item\(count == 1 ? "" : "s") to \(name)"
        default:
            return "Exported \(rowsWritten.formatted()) row\(rowsWritten == 1 ? "" : "s") to \(name)"
        }
    }

    /// The files a per-table export into `folder` would replace.
    func existingFiles(in folder: URL) -> [String] {
        perTableNames().map(\.file).filter { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
    }

    /// Writes the export to `url`, or with one file per table into the folder
    /// `url`. The returned task ends when it is done, failed or was cancelled;
    /// then no file of an unfinished export is left.
    @discardableResult
    func start(to url: URL) -> Task<Void, Never>? {
        guard canExport else { return nil }
        finishedFile = nil
        finishedFiles = []
        rowsWritten = 0
        if !Store.isOverridden { UserDefaults.standard.set(namePattern, forKey: Self.namePatternKey) }
        let split = splitsFiles
        let names = Dictionary(perTableNames().map { ($0.object, $0.file) }, uniquingKeysWith: { first, _ in first })
        let items = items
        let options = options
        let database = database
        let format = format
        let source = source
        let tables = dataTables
        let content = content
        let result = result
        let csv = csv.options
        let compression = compression
        let initial = ExportProgress(text: "Connecting…", done: 0, total: format == .sql ? items.count : 1)
        return job.start(progress: initial) { job in
            var output: ExportOutput?
            do {
                output = split
                    ? ExportOutput(perTable: { object in
                        try DumpFile(url: url.appending(path: names[object] ?? object), compression: compression)
                    })
                    : ExportOutput(file: try DumpFile(url: url, compression: compression))
                let report = job.reporter()
                if let dataFormat = format.data {
                    if source == .result, let result {
                        let writer = DataExport.Writer(format: dataFormat, shape: .rows(statement: result.statement), csv: csv)
                        try await Self.write(result, with: writer, to: try output!.file(for: "result"), progress: report)
                        self.rowsWritten = result.rows.count
                    } else {
                        let sources = source == .content ? content.map { [$0.source] } ?? [] : tables.map { DataSource(table: $0) }
                        let shape: DataExport.Shape = source == .content
                            ? .rows(statement: content.map { $0.source.select(in: $0.database, keys: []) } ?? "")
                            : .tables(database: database)
                        self.rowsWritten = try await job.connection().exportData(
                            sources, from: content?.database ?? database,
                            writer: DataExport.Writer(format: dataFormat, shape: shape, csv: csv),
                            to: output!, progress: report)
                    }
                } else {
                    try await job.connection().exportSQL(items, from: database, options: options, to: output!,
                                                         progress: report)
                }
                try Task.checkCancellation()
                try output!.close()
                self.finishedFile = url
                self.finishedFiles = output!.urls
            } catch {
                // No file of an unfinished export is left.
                output?.discard()
                throw error
            }
        }
    }

    /// Writes the Query view's results, held in memory, off the main actor, a page at a time.
    @concurrent nonisolated private static func write(_ result: QueryRows, with writer: DataExport.Writer,
                                                      to file: DumpFile,
                                                      progress: @Sendable (ExportProgress) -> Void) async throws {
        let columns = result.columns
        let rows = result.rows
        do {
            var writer = writer
            try file.write(writer.start() + writer.begin("result", columns: columns))
            var written = 0
            for start in stride(from: 0, to: rows.count, by: DatabaseClient.exportPageSize) {
                try Task.checkCancellation()
                let page = Array(rows[start..<min(rows.count, start + DatabaseClient.exportPageSize)])
                try file.write(writer.append(page))
                written += page.count
                progress(ExportProgress(text: "Writing rows", done: 0, total: 1, rows: written, tableRows: rows.count,
                                        bytes: file.bytesWritten))
            }
            try file.write(writer.end() + writer.finish())
        }
    }

    /// Stops the export between pages and kills the statement running now.
    func cancel() {
        job.cancel()
    }

    func showInFinder() {
        guard finishedFile != nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting(finishedFiles)
    }
}
