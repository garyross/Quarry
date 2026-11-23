import Foundation

/// What a running import has done, for the Import sheet's progress bar (S-044).
public struct ImportProgress: Sendable, Equatable {
    public var statements: Int
    public var errors: Int
    /// Bytes of the file read, of `totalBytes` (compressed bytes for a .gz file).
    public var bytesRead: Int
    public var totalBytes: Int
    /// A CSV import's records sent so far; nil for a SQL file.
    public var rows: Int?

    public init(statements: Int = 0, errors: Int = 0, bytesRead: Int = 0, totalBytes: Int = 0, rows: Int? = nil) {
        self.rows = rows
        self.statements = statements
        self.errors = errors
        self.bytesRead = bytesRead
        self.totalBytes = totalBytes
    }

    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(bytesRead) / Double(totalBytes)) : 0
    }

    /// "Read 1.2 MB of 3.4 MB · 120 statements".
    public var text: String {
        let read = ByteCountFormatter.string(fromByteCount: Int64(bytesRead), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        if let rows { return "Read \(read) of \(total) · \(rows.formatted()) row\(rows == 1 ? "" : "s")" }
        return "Read \(read) of \(total) · \(statements.formatted()) statement\(statements == 1 ? "" : "s")"
    }
}

/// A statement of an import that the server refused.
public struct ImportFailure: Sendable, Equatable, Identifiable {
    /// 1-based, counting every statement of the file.
    public var number: Int
    /// The statement's start, for the error list.
    public var statement: String
    public var message: String
    /// What failed, when not "Statement n": "Rows 1–1,000" for a CSV batch.
    public var label: String?
    public var id: Int { number }

    public init(number: Int, statement: String, message: String, label: String? = nil) {
        self.label = label
        self.number = number
        self.statement = statement
        self.message = message
    }

    /// "Statement 12: Table 'x' already exists".
    public var text: String { "\(label ?? "Statement \(number)"): \(message)" }
}

/// What to do after a statement fails.
public enum ImportErrorChoice: Sendable {
    /// Skip this statement and go on; ask again at the next error.
    case `continue`
    /// Skip this one and every later error without asking.
    case skipAll
    case stop
}

/// What an import did.
public struct ImportSummary: Sendable, Equatable {
    /// Statements sent to the server, failed ones included.
    public var statements = 0
    public var failures: [ImportFailure] = []
    /// It stopped at an error, as asked.
    public var stopped = false
    /// A CSV import's records that went in (in statements that worked).
    public var rows = 0

    public init(statements: Int = 0, failures: [ImportFailure] = [], stopped: Bool = false) {
        self.statements = statements
        self.failures = failures
        self.stopped = stopped
    }
}

extension DatabaseClient {
    /// The server's "Query was empty", which a statement of comments gives; not a failure.
    public static let emptyQueryCode = 1065

    /// Runs the SQL file `reader` reads, statement by statement, in `database`
    /// (or none: the file's own USE statements pick one). Run it on a
    /// `secondConnection()`: the file's SET statements stay on that connection.
    /// `onError` decides what happens after a statement fails. Cancelling the
    /// task stops it between statements; what ran stays.
    public func importSQL(from reader: DumpReader, into database: String?, encoding: String.Encoding = .utf8,
                          onError: @Sendable (ImportFailure) async -> ImportErrorChoice,
                          progress: @Sendable (ImportProgress) -> Void) async throws -> ImportSummary {
        if let database { try await use(database) }
        var splitter = SQLStreamSplitter(engine: dialect.engine)
        var summary = ImportSummary()
        var skipAll = false
        var report = ImportProgress(totalBytes: reader.totalBytes)
        var batch = SQLiteImportBatch()
        progress(report)

        // What ran stays, as on a server: an open batch commits when the import ends early.
        do {
            reading: while true {
                try Task.checkCancellation()
                let chunk = try reader.read()
                let statements = chunk.map { splitter.append($0) } ?? splitter.finish()
                for bytes in statements {
                    try Task.checkCancellation()
                    guard let sql = String(bytes: bytes, encoding: encoding) else {
                        throw DatabaseError(message: "Statement \(summary.statements + 1) isn’t valid "
                                            + "\(String.localizedName(of: encoding)). Choose the file’s encoding and import again.")
                    }
                    summary.statements += 1
                    if dialect.engine == .sqlite {
                        for control in batch.before(sql) { _ = await execute(control) }
                    }
                    let problem = await execute(sql)
                    if dialect.engine == .sqlite, let control = batch.after() { _ = await execute(control) }
                    guard let problem else { continue }
                    try Task.checkCancellation()
                    guard problem.code != Self.emptyQueryCode else { continue }
                    if wasLost {
                        throw DatabaseError(message: "The connection was lost after \(summary.statements - 1) statements. "
                                            + "What ran stays in the database.")
                    }
                    let failure = ImportFailure(number: summary.statements, statement: String(sql.prefix(200)),
                                                message: problem.message)
                    summary.failures.append(failure)
                    report.errors = summary.failures.count
                    guard !skipAll else { continue }
                    // The file stays unlocked while the person decides.
                    if let control = batch.close() { _ = await execute(control) }
                    switch await onError(failure) {
                    case .continue: break
                    case .skipAll: skipAll = true
                    case .stop:
                        summary.stopped = true
                        break reading
                    }
                }
                report.statements = summary.statements
                report.bytesRead = reader.bytesRead
                progress(report)
                if let line = splitter.refusedDelimiterLine {
                    throw DatabaseError(message: Self.delimiterRefusal(line: line))
                }
                if chunk == nil { break }
            }
        } catch {
            if let control = batch.close() { _ = await execute(control) }
            throw error
        }
        if let control = batch.close() { _ = await execute(control) }
        report.statements = summary.statements
        progress(report)
        return summary
    }

    /// Why a SQLite import stopped at a DELIMITER line (S-071).
    public static func delimiterRefusal(line: Int) -> String {
        "Line \(line.formatted()) sets a DELIMITER, which SQLite doesn’t read: end each statement with ; "
            + "(a trigger’s BEGIN … END needs nothing else). Nothing from that line on ran."
    }

    /// Runs one statement of an import; the error, or nil when it worked.
    func execute(_ sql: String) async -> DatabaseError? {
        await acquire()
        defer { release() }
        do {
            _ = try await perform(sql, countingRows: false)
            return nil
        } catch {
            return DatabaseError.from(error)
        }
    }
}
