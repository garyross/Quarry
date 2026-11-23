import Foundation
import SQLite3

/// One SQLite file opened with the system's SQLite (S-068). Statements run on
/// the driver's own queue, so a long one never blocks a thread Swift needs.
/// `interrupt()` stops a running statement (`sqlite3_interrupt`) from anywhere.
final class SQLiteDriver: SQLDriver, @unchecked Sendable {
    /// SQLite's own error numbers, as `DatabaseError.code`.
    static let busyCode = Int(SQLITE_BUSY)
    static let interruptCode = Int(SQLITE_INTERRUPT)
    static let cantOpenCode = Int(SQLITE_CANTOPEN)
    static let notADatabaseCode = Int(SQLITE_NOTADB)
    /// How long a statement waits for another app's write lock (S-068).
    static let busyTimeout: Int32 = 5000

    private let queue: DispatchQueue
    /// The connection; nil once closed. Touched only on `queue`, except `interrupt`.
    private var handle: OpaquePointer?
    private let lock = NSLock()
    private let url: URL
    /// The file's identity when it was opened, so a file moved or deleted underneath shows as lost.
    private let fileID: FileID?
    private var changes = 0
    private var lastRowID: Int64 = 0

    let serverVersion: String
    var connectionID: Int? { nil }
    var encryption: Encryption? { nil }

    private init(handle: OpaquePointer, url: URL, queue: DispatchQueue) {
        self.handle = handle
        self.url = url
        self.queue = queue
        self.fileID = FileID(url)
        self.serverVersion = String(cString: sqlite3_libversion())
    }

    /// The SQLite version this Mac has, "3.51.0".
    static var libraryVersion: String { String(cString: sqlite3_libversion()) }

    /// Opens an existing file, never making one. Throws `DatabaseError` in the
    /// words of S-068's states: missing, not a SQLite file, busy.
    static func open(_ url: URL, readOnly: Bool) async throws -> SQLiteDriver {
        let queue = DispatchQueue(label: "app.quarry.sqlite")
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try openNow(url, readOnly: readOnly, queue: queue) })
            }
        }
    }

    private static func openNow(_ url: URL, readOnly: Bool, queue: DispatchQueue) throws -> SQLiteDriver {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else { throw missing(name) }
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(url.path, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            sqlite3_close_v2(db)
            if status == SQLITE_CANTOPEN { throw missing(name) }
            throw DatabaseError(message: "Quarry couldn’t open “\(name)”.", code: Int(status))
        }
        sqlite3_busy_timeout(db, busyTimeout)
        sqlite3_extended_result_codes(db, 1)
        // S-069: foreign keys are enforced on Quarry's connection (SQLite leaves them off per connection).
        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        let driver = SQLiteDriver(handle: db, url: url, queue: queue)
        // Reading the schema finds a file that isn't SQLite, or one another app is writing.
        do {
            _ = try driver.executeNow("SELECT count(*) FROM sqlite_schema", encoding: .utf8mb4)
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
        return driver
    }

    /// File > New SQLite File… (S-068): an empty database at `url`, which must not exist yet.
    public static func create(_ url: URL) throws {
        // The save panel already asked to replace a file; Quarry still never writes over one.
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw DatabaseError(message: "“\(url.lastPathComponent)” already exists.",
                                suggestion: "Move it to the Trash first, or choose another name.")
        }
        var db: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        defer { sqlite3_close_v2(db) }
        guard status == SQLITE_OK, let db else {
            throw DatabaseError(message: "Quarry couldn’t make “\(url.lastPathComponent)”.", code: Int(status))
        }
        // An empty file has no header until something is written; this writes page 1.
        guard sqlite3_exec(db, "PRAGMA user_version = 0; VACUUM", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError(message: String(cString: sqlite3_errmsg(db)), code: Int(sqlite3_errcode(db)))
        }
    }

    /// Whether the file starts with SQLite's header, "SQLite format 3\0".
    public static func isSQLiteFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 16)) ?? Data()
        return header == Data("SQLite format 3\0".utf8)
    }

    static func missing(_ name: String) -> DatabaseError {
        DatabaseError(message: "Can’t find “\(name)”. It was moved or deleted.", code: cantOpenCode,
                      suggestion: "Locate the file, or remove the connection.")
    }

    // MARK: SQLDriver

    var isClosed: Bool { lock.withLock { handle == nil } }

    func execute(_ sql: String, encoding: ViewEncoding) async throws -> (columns: [ResultColumn], rows: [[CellValue]]) {
        try await onQueue { try self.executeNow(sql, encoding: encoding) }
    }

    func stream(_ sql: String, encoding: ViewEncoding,
                row: @escaping @Sendable (_ columns: () -> [ResultColumn], _ cells: () -> [CellValue]) -> Void) async throws {
        _ = try await onQueue {
            try self.step(sql) { statement, columns in
                row({ columns }, { Self.cells(statement) })
            }
        }
    }

    func affectedRows() async throws -> Int { await onQueueValue { self.changes } }

    func lastInsertID() async throws -> UInt64 { await onQueueValue { UInt64(max(0, self.lastRowID)) } }

    /// There is no server to keep awake; this finds a file moved or deleted while open.
    func ping() async throws {
        try await onQueue { try self.checkFile() }
    }

    func close() async {
        await onQueueValue {
            let db = self.lock.withLock { () -> OpaquePointer? in
                defer { self.handle = nil }
                return self.handle
            }
            sqlite3_close_v2(db)
        }
    }

    /// An agent's connection (S-073): no ATTACH (a limit of 0 attached files), no
    /// functions with side effects from the file's views and triggers, and for reads
    /// `query_only`, so SQLite itself refuses every write.
    func restrictForAgent(queryOnly: Bool) async throws {
        try await onQueue {
            guard let db = self.lock.withLock({ self.handle }) else { throw DatabaseError(message: "The file was closed.", code: -1) }
            sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0)
            let pragmas = "PRAGMA trusted_schema = OFF" + (queryOnly ? "; PRAGMA query_only = ON" : "")
            let status = sqlite3_exec(db, pragmas, nil, nil, nil)
            guard status == SQLITE_OK else { throw self.error(db, status) }
        }
    }

    /// Stops the statement that is running, if any (Cancel Query, S-068).
    func interrupt() {
        lock.withLock { if let handle { sqlite3_interrupt(handle) } }
    }

    func isLost(_ error: any Error) -> Bool {
        if isClosed { return true }
        guard let code = (error as? DatabaseError)?.code else { return false }
        // The file went away or became unreadable underneath the connection.
        return code == -1 || code & 0xff == Int(SQLITE_IOERR) || code == Int(SQLITE_READONLY) | (4 << 8)
    }

    func describe(_ error: any Error) -> DatabaseError {
        error as? DatabaseError ?? DatabaseError(message: error.localizedDescription)
    }

    // MARK: Running statements (on `queue`)

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func onQueueValue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// The file at the path is still the one opened.
    private func checkFile() throws {
        guard let fileID, FileID(url) == fileID else {
            throw DatabaseError(message: "“\(url.lastPathComponent)” was moved or deleted.", code: -1)
        }
    }

    private func executeNow(_ sql: String, encoding: ViewEncoding) throws -> (columns: [ResultColumn], rows: [[CellValue]]) {
        var rows: [[CellValue]] = []
        let columns = try step(sql) { statement, _ in rows.append(Self.cells(statement)) }
        return (columns, rows)
    }

    /// Prepares `sql` (one statement; a trailing semicolon or comment is fine) and
    /// steps through its rows. Returns the result's columns, even with no rows.
    @discardableResult
    private func step(_ sql: String, row: (OpaquePointer, [ResultColumn]) -> Void) throws -> [ResultColumn] {
        try checkFile()
        guard let db = lock.withLock({ handle }) else {
            throw DatabaseError(message: "The file was closed.", code: -1)
        }
        var statement: OpaquePointer?
        var tail: UnsafePointer<CChar>?
        let prepared = sql.withCString { text in
            let status = sqlite3_prepare_v2(db, text, -1, &statement, &tail)
            let rest = tail.map { String(cString: $0) } ?? ""
            return (status, rest)
        }
        guard prepared.0 == SQLITE_OK else { throw error(db, prepared.0) }
        guard let statement else {
            // Only whitespace or comments.
            changes = 0
            return []
        }
        defer { sqlite3_finalize(statement) }
        if !prepared.1.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";"))).isEmpty {
            throw DatabaseError(message: "Run one statement at a time.",
                                suggestion: "Use Run All (⌥⌘R) for several statements.")
        }
        let columns = Self.columns(statement, db: db)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                row(statement, columns)
            } else if status == SQLITE_DONE {
                break
            } else {
                throw error(db, status)
            }
        }
        // sqlite3_changes keeps the last INSERT/UPDATE/DELETE's count; a statement that only reads changed nothing.
        changes = sqlite3_stmt_readonly(statement) != 0 ? 0 : Int(sqlite3_changes64(db))
        lastRowID = sqlite3_last_insert_rowid(db)
        return columns
    }

    private func error(_ db: OpaquePointer, _ status: Int32) -> DatabaseError {
        let code = Int(sqlite3_extended_errcode(db))
        let name = url.lastPathComponent
        switch status & 0xff {
        case SQLITE_BUSY, SQLITE_LOCKED:
            return DatabaseError(message: "“\(name)” is busy. Another app is writing to it.", code: Self.busyCode,
                                 suggestion: "Try again when the other app is done.")
        case SQLITE_NOTADB:
            return DatabaseError(message: "“\(name)” isn’t a SQLite database.", code: Self.notADatabaseCode)
        case SQLITE_INTERRUPT:
            return DatabaseError(message: "The query was cancelled.", code: DatabaseClient.queryInterruptedCode)
        case SQLITE_READONLY where code == Int(SQLITE_READONLY):
            return DatabaseError(message: "“\(name)” is open read only.", code: code,
                                 suggestion: "Reconnect without Open Read Only to change it.")
        default:
            return DatabaseError(message: String(cString: sqlite3_errmsg(db)), code: code)
        }
    }

    // MARK: Decoding

    /// The result's columns: name, table, declared type, and whether the column
    /// is in its table's primary key (S-069), so edits find the row by it.
    static func columns(_ statement: OpaquePointer, db: OpaquePointer) -> [ResultColumn] {
        (0..<sqlite3_column_count(statement)).map { index in
            let declared = sqlite3_column_decltype(statement, index).map { String(cString: $0) } ?? ""
            let affinity = SQLiteAffinity(declared)
            let table = sqlite3_column_table_name(statement, index).map { String(cString: $0) } ?? ""
            let database = sqlite3_column_database_name(statement, index).map { String(cString: $0) } ?? ""
            let origin = sqlite3_column_origin_name(statement, index).map { String(cString: $0) } ?? ""
            var primaryKey: Int32 = 0
            if !table.isEmpty, !origin.isEmpty {
                sqlite3_table_column_metadata(db, database, table, origin, nil, nil, nil, &primaryKey, nil)
            }
            return ResultColumn(name: sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "",
                                table: table, database: database, orgName: origin,
                                typeName: declared.uppercased(), isBinary: affinity == .blob && !declared.isEmpty,
                                isNumeric: affinity == .integer || affinity == .real || affinity == .numeric,
                                isPrimaryKey: primaryKey != 0)
        }
    }

    /// One row's cells, as SQLite stored them: INTEGER and REAL as their text,
    /// TEXT as text, BLOB as bytes, NULL as NULL.
    static func cells(_ statement: OpaquePointer) -> [CellValue] {
        (0..<sqlite3_column_count(statement)).map { index in
            switch sqlite3_column_type(statement, index) {
            case SQLITE_NULL:
                return .null
            case SQLITE_INTEGER:
                return .text(String(sqlite3_column_int64(statement, index)))
            case SQLITE_FLOAT:
                return .text(SQLiteValue.text(sqlite3_column_double(statement, index)))
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, index))
                guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .binary(Data()) }
                return .binary(Data(bytes: bytes, count: count))
            default:
                let count = Int(sqlite3_column_bytes(statement, index))
                guard let text = sqlite3_column_text(statement, index) else { return .text("") }
                let buffer = UnsafeBufferPointer(start: text, count: count)
                if let string = String(validating: buffer, as: UTF8.self) { return .text(string) }
                return .binary(Data(buffer))
            }
        }
    }
}

/// How SQLite reads a column's declared type (its type affinity rules, §3.1).
public enum SQLiteAffinity: Sendable, Equatable {
    case integer, text, blob, real, numeric

    public init(_ declared: String) {
        let type = declared.uppercased()
        if type.contains("INT") { self = .integer }
        else if type.contains("CHAR") || type.contains("CLOB") || type.contains("TEXT") { self = .text }
        else if type.contains("BLOB") || type.isEmpty { self = .blob }
        else if type.contains("REAL") || type.contains("FLOA") || type.contains("DOUB") { self = .real }
        else { self = .numeric }
    }
}

extension SQLiteAffinity {
    /// The cell's hover help when SQLite stored the value with another type than
    /// the column's (S-069): "Stored as TEXT" for words in an INTEGER column,
    /// "Stored as BLOB" for bytes in a typed column. Nil when it matches.
    /// Integers and reals both arrive as text, so only these two can be told apart.
    public func storedNote(_ value: CellValue) -> String? {
        switch (self, value) {
        case (.blob, _): return nil
        case (_, .binary): return "Stored as BLOB"
        case (.integer, .text(let text)), (.real, .text(let text)), (.numeric, .text(let text)):
            return Double(text) == nil ? "Stored as TEXT" : nil
        default: return nil
        }
    }
}

public enum SQLiteValue {
    /// A REAL as SQLite's shell prints it: "2.5", "10.0", "1.0e+20".
    public static func text(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 { return String(format: "%.1f", value) }
        return String(value)
    }
}

/// A file's device and inode: the same file even after a rename elsewhere.
private struct FileID: Equatable {
    let device: UInt64
    let inode: UInt64

    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        self.device = device
        self.inode = inode
    }
}

/// What the app needs to know about SQLite files without a connection (S-068).
public enum SQLiteFile {
    /// File > Open… and the Connect form's Choose… list these; any file with
    /// SQLite's header opens too.
    public static let extensions = ["sqlite", "sqlite3", "db", "db3"]
    /// `DatabaseError.code` when the file isn't where it was.
    public static let missingCode = SQLiteDriver.cantOpenCode
    /// The SQLite this Mac has, "3.51.0".
    public static var version: String { SQLiteDriver.libraryVersion }

    public static func isSQLite(_ url: URL) -> Bool { SQLiteDriver.isSQLiteFile(url) }

    /// An empty database at `url`, which must not exist yet.
    public static func create(_ url: URL) throws { try SQLiteDriver.create(url) }

    /// A file Quarry should open as SQLite: its header says so, or it has a SQLite extension and no header yet.
    public static func opens(_ url: URL) -> Bool {
        isSQLite(url) || (extensions.contains(url.pathExtension.lowercased())
            && ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1) == 0)
    }
}
