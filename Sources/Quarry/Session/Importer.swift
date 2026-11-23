import AppKit
import Foundation
import QuarryKit
import QuarryControllers

/// The Import sheet (S-044): a .sql or .sql.gz file, its encoding, what to do
/// when a statement fails, and the running import with its progress and
/// Cancel. The import runs on a connection of its own, so the window keeps
/// browsing; its SET statements stay on that connection. A CSV file (S-045)
/// goes into a table through `csv`'s field mapping.
@MainActor @Observable
final class Importer: Identifiable {
    /// What happens when the server refuses a statement.
    enum ErrorPolicy: String, CaseIterable, Identifiable {
        case ask, skip, stop
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: "Ask Me"
            case .skip: "Skip It and Continue"
            case .stop: "Stop the Import"
            }
        }
    }

    enum Encoding: String, CaseIterable, Identifiable {
        case utf8, latin1, windows1252
        var id: String { rawValue }
        var title: String {
            switch self {
            case .utf8: "UTF-8"
            case .latin1: "Latin 1 (ISO 8859-1)"
            case .windows1252: "Western (Windows 1252)"
            }
        }
        var value: String.Encoding {
            switch self {
            case .utf8: .utf8
            case .latin1: .isoLatin1
            case .windows1252: .windowsCP1252
            }
        }
    }

    enum Format: String, CaseIterable, Identifiable {
        case sql, csv
        var id: String { rawValue }
        var title: String { self == .sql ? "SQL" : "CSV" }
    }

    /// The database selected when the sheet opened; nil runs the file as it is.
    let database: String?
    /// The table selected when the sheet opened: a CSV file's first target.
    let table: String?
    var file: URL?
    /// Text from the clipboard (S-046), saved to `file` for the import.
    private(set) var clipboard: String?
    var format = Format.sql
    let csv: CSVImporter
    var encoding = Encoding.utf8
    var errorPolicy = ErrorPolicy.ask

    /// A failed statement waiting for Continue, Skip All Errors or Stop.
    private(set) var pendingFailure: ImportFailure?
    private(set) var summary: ImportSummary?
    private var choice: CheckedContinuation<ImportErrorChoice, Never>?
    /// The running import, on its own connection; its progress stays after the end.
    private let job: ConnectionJob<ImportProgress>
    private let client: DatabaseClient

    var progress: ImportProgress? { job.progress }
    var error: String? { job.error }
    var wasCancelled: Bool { job.wasCancelled }

    init(database: String?, table: String? = nil, client: DatabaseClient, file: URL? = nil) {
        self.database = database
        self.table = table
        self.client = client
        csv = CSVImporter(engine: client.dialect.engine)
        job = ConnectionJob(client: client, failurePrefix: "Couldn’t import: ", clearsProgress: false)
        if let file { choose(file) }
    }

    /// Import from Clipboard (S-046): the text goes to a temporary UTF-8
    /// file, read like any other; the format and separator are guessed.
    convenience init(database: String?, table: String? = nil, client: DatabaseClient, clipboard text: String) {
        self.init(database: database, table: table, client: client)
        let url = FileManager.default.temporaryDirectory.appending(path: "Quarry Clipboard \(UUID().uuidString).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        choose(url)
        clipboard = text
        csv.newTableName = "clipboard"
        switch ClipboardText.guess(text) {
        case .sql: format = .sql
        case .csv(let separator):
            format = .csv
            csv.format.separator = CSVFormat.Separator(rawValue: separator) ?? .comma
        }
    }

    /// Removes the clipboard's temporary file when the sheet closes.
    func discardClipboardFile() {
        guard clipboard != nil, let file else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// The file's name, or "the clipboard".
    var sourceName: String? { clipboard != nil ? "the clipboard" : file?.lastPathComponent }

    var title: String { database.map { "Import into \u{201C}\($0)\u{201D}" } ?? "Import" }
    var isWorking: Bool { job.isRunning }
    var isMapping: Bool { format == .csv && csv.step == .mapping }
    var canImport: Bool {
        guard file != nil, !isWorking else { return false }
        return format == .sql || (isMapping && csv.problem == nil)
    }
    /// CSV options filled in: Next reads the file and shows the mapping.
    var canGoNext: Bool { format == .csv && !isMapping && file != nil && database != nil && !csv.isLoading && !isWorking }
    var isFinished: Bool { summary != nil || error != nil || wasCancelled }

    /// "quarry_demo.sql.gz, 1.2 MB".
    var fileSummary: String? {
        guard let file else { return nil }
        if let clipboard { return ClipboardText.summary(clipboard) }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        return file.lastPathComponent + ", " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// "Ran 1,234 statements from quarry_demo.sql", with the failures counted.
    var finishedText: String? {
        guard let summary, let source = sourceName else { return nil }
        if format == .csv {
            let rows = "\(summary.rows.formatted()) row\(summary.rows == 1 ? "" : "s")"
            let failed = summary.failures.count
            if summary.stopped { return "Stopped after an error, with \(rows) imported. What ran stays in the database." }
            let into = "Imported \(rows) into \u{201C}\(csv.tableName)\u{201D}"
            return failed == 0 ? into : into + "; \(failed.formatted()) statement\(failed == 1 ? "" : "s") failed"
        }
        let ran = "\(summary.statements.formatted()) statement\(summary.statements == 1 ? "" : "s")"
        let failed = summary.failures.count
        if summary.stopped { return "Stopped at statement \(summary.statements.formatted()), after an error. What ran stays in the database." }
        if failed == 0 { return "Ran \(ran) from \(source)" }
        return "Ran \(ran) from \(source); \(failed.formatted()) failed"
    }

    var cancelledText: String {
        if format == .csv {
            let rows = summary?.rows ?? progress?.rows ?? 0
            return "Import cancelled after \(rows.formatted()) row\(rows == 1 ? "" : "s"). What ran stays in the database."
        }
        let count = progress?.statements ?? summary?.statements ?? 0
        return "Import cancelled after \(count.formatted()) statement\(count == 1 ? "" : "s"). What ran stays in the database."
    }

    /// Picks a new file, clearing the last run's result.
    func choose(_ url: URL) {
        discardClipboardFile()
        clipboard = nil
        file = url
        format = ["csv", "tsv", "tab", "txt"].contains(url.pathExtension.lowercased()) ? .csv : .sql
        csv.adopt(url)
        summary = nil
        job.reset()
    }

    /// Runs the file. The returned task ends when the import is done, failed,
    /// stopped or was cancelled.
    @discardableResult
    func start() -> Task<Void, Never>? {
        guard canImport, let file else { return nil }
        if format == .csv { return startCSV(file) }
        summary = nil
        let database = database
        let encoding = encoding.value
        return job.start(progress: ImportProgress()) { job in
            let reader = try DumpReader(url: file)
            defer { reader.close() }
            self.summary = try await job.connection().importSQL(
                from: reader, into: database, encoding: encoding,
                onError: { failure in await self.decide(failure) }, progress: job.reporter())
            if Task.isCancelled {
                job.progress?.statements = self.summary?.statements ?? 0
                self.summary = nil
                throw CancellationError()
            }
        }
    }

    /// Next: reads the file's first records and the tables, and shows the mapping.
    func next() async {
        guard canGoNext, let file, let database else { return }
        await csv.loadMapping(file: file, encoding: encoding.value, client: client, database: database,
                              preferredTable: table)
    }

    /// Back from the mapping to the file's options.
    func back() {
        guard !isWorking else { return }
        csv.step = .options
        summary = nil
        job.reset()
    }

    func chooseTarget(_ target: CSVImporter.Target) {
        guard let database else { return }
        Task { await csv.choose(target, client: client, database: database) }
    }

    /// Imports the CSV file as mapped, creating the new table first.
    private func startCSV(_ file: URL) -> Task<Void, Never>? {
        guard let database else { return nil }
        summary = nil
        let encoding = encoding.value
        let parser = CSVStreamParser(options: csv.options, encoding: encoding)
        let skipHeader = csv.header
        let mapping = csv.mapping
        let table = csv.tableName
        let create = csv.createStatement(database: database)
        return job.start(progress: ImportProgress(rows: 0)) { job in
            let reader = try DumpReader(url: file)
            defer { reader.close() }
            let importer = try await job.connection()
            if let create { _ = try await importer.run(create) }
            self.summary = try await importer.importCSV(
                from: reader, parser: parser, skipHeader: skipHeader, mapping: mapping, table: table,
                database: database, onError: { failure in await self.decide(failure) }, progress: job.reporter())
            if Task.isCancelled {
                job.progress?.rows = self.summary?.rows ?? 0
                self.summary = nil
                throw CancellationError()
            }
        }
    }

    /// After a failed statement: the policy's answer, or the person's.
    private func decide(_ failure: ImportFailure) async -> ImportErrorChoice {
        switch errorPolicy {
        case .skip: return .continue
        case .stop: return .stop
        case .ask:
            guard !Task.isCancelled else { return .stop }
            return await withCheckedContinuation { continuation in
                choice = continuation
                pendingFailure = failure
            }
        }
    }

    /// Continue, Skip All Errors or Stop, after a failed statement.
    func answer(_ answer: ImportErrorChoice) {
        pendingFailure = nil
        choice?.resume(returning: answer)
        choice = nil
    }

    /// Stops between statements and kills the one running now. What ran stays.
    func cancel() {
        job.cancel()
        if choice != nil { answer(.stop) }
    }

    func revealFile() {
        guard let file else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
