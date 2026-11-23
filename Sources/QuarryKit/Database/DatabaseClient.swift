import Foundation

/// One open connection to a database. All queries go through here, one at a
/// time, off the main thread. The engine's wire is a `SQLDriver`, its SQL a
/// `SQLDialect` (S-067); this actor adds the queue, the Console and lost connections.
public actor DatabaseClient {
    let driver: any SQLDriver
    /// The engine's SQL for the catalog and agents (S-067).
    public nonisolated let dialect: any SQLDialect
    public nonisolated let serverVersion: String
    public nonisolated let configuration: ConnectionDetails.DriverConfiguration
    /// The server's thread id for this connection, for KILL QUERY (S-036).
    public nonisolated let connectionID: Int?
    /// How the connection is encrypted, from the server's session status; nil without SSL (S-058).
    public nonisolated let encryption: Encryption?
    /// Kept to open a second, short connection that cancels a query.
    nonisolated let details: ConnectionDetails

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Callers waiting in `untilLost` (S-050).
    private var lostWaiters: [CheckedContinuation<Void, Never>] = []
    private var reportedLost = false
    /// The database selected on this connection, for the Console (S-039).
    private var selectedDatabase: String?
    /// Where statements are logged (S-039).
    private nonisolated let console: ConsoleLog

    private init(driver: any SQLDriver, dialect: any SQLDialect, details: ConnectionDetails) {
        self.driver = driver
        self.dialect = dialect
        self.serverVersion = driver.serverVersion
        self.connectionID = driver.connectionID
        self.encryption = driver.encryption
        self.details = details
        self.configuration = details.driverConfiguration
        self.console = .shared
        let database = details.database.trimmingCharacters(in: .whitespaces)
        self.selectedDatabase = database.isEmpty ? nil : database
    }

    /// Opens a connection. Throws `DatabaseError`, or `SSHQuestion` when SSH
    /// needs an answer first (S-047).
    public static func connect(_ details: ConnectionDetails) async throws -> DatabaseClient {
        switch details.engine {
        case .mysql:
            let driver = try await MySQLDriver.connect(details, timeout: connectTimeout)
            return DatabaseClient(driver: driver, dialect: MySQLDialect(), details: details)
        case .sqlite:
            guard let url = details.fileURL else { throw DatabaseError(message: "Choose a SQLite file.") }
            let driver = try await SQLiteDriver.open(url, readOnly: details.readOnly)
            return DatabaseClient(driver: driver, dialect: SQLiteDialect(), details: details)
        }
    }

    /// Settings > Network (S-054): seconds a login may take, stored by the app.
    public static let connectTimeoutKey = "network.timeout"
    public static let defaultConnectTimeout = 20

    /// Seconds to wait for the server's handshake before giving up.
    public static var connectTimeout: Int {
        let stored = UserDefaults.standard.integer(forKey: connectTimeoutKey)
        return (1...600).contains(stored) ? stored : defaultConnectTimeout
    }

    /// "MariaDB 13.0.2", "MySQL 8.4.2", or "SQLite 3.51" for a file.
    public nonisolated var serverDescription: String {
        if dialect.engine == .sqlite {
            return "SQLite " + serverVersion.split(separator: ".").prefix(2).joined(separator: ".")
        }
        let number = serverVersion.split(separator: "-").first.map(String.init) ?? serverVersion
        return serverVersion.localizedCaseInsensitiveContains("mariadb") ? "MariaDB \(number)" : "MySQL \(number)"
    }

    public func close() async {
        resumeLostWaiters()
        await driver.close()
    }

    public nonisolated var isClosed: Bool { driver.isClosed }

    /// A SQLite file opened with Open Read Only: nothing can write (S-068).
    public nonisolated var isReadOnly: Bool { details.engine == .sqlite && details.readOnly }

    // MARK: Lost connections (S-050)

    /// Returns when a statement finds the connection gone (the server went away,
    /// killed it, or closed it after `wait_timeout`), or when it is closed here.
    public func untilLost() async {
        guard !reportedLost else { return }
        await withCheckedContinuation { lostWaiters.append($0) }
    }

    /// Whether a statement found the connection gone.
    public var wasLost: Bool { reportedLost }

    private func reportLost() {
        reportedLost = true
        resumeLostWaiters()
    }

    private func resumeLostWaiters() {
        let waiting = lostWaiters
        lostWaiters = []
        waiting.forEach { $0.resume() }
    }

    /// Maps an error and reports a lost connection.
    func failure(_ error: any Error) -> DatabaseError {
        if driver.isLost(error) {
            reportLost()
            return DatabaseError(message: "The connection to the server was lost.", code: (error as? DatabaseError)?.code,
                                 suggestion: "Reconnect and try again.")
        }
        return driver.describe(error)
    }

    /// Keeps an idle connection open past the server's `wait_timeout` (S-050).
    /// Skipped while a statement runs: that already keeps it open. A ping that
    /// finds the connection gone reports it, so the sheet shows while idle.
    public func keepAlive() async {
        guard !busy else { return }
        await acquire()
        defer { release() }
        do {
            try await driver.ping()
        } catch {
            _ = failure(error)
        }
    }

    /// A new connection to the same server as this one, for work that should
    /// not make browsing wait (export, import). Close it when done.
    /// `readOnly` opens a SQLite file read only, so an export can't write (S-071);
    /// a server connection is the same either way.
    public func secondConnection(readOnly: Bool = false) async throws -> DatabaseClient {
        var other = details
        if readOnly, other.engine == .sqlite { other.readOnly = true }
        return try await Self.connect(other)
    }

    /// Stops the statement this connection is running, on the server: KILL QUERY
    /// from a second, short-lived connection, since this one is busy (S-036).
    /// The connection itself stays open. Throws `DatabaseError`.
    public nonisolated func cancelRunningQuery() async throws {
        // A SQLite file runs in this process: interrupt the statement directly (S-068).
        if let sqlite = driver as? SQLiteDriver {
            sqlite.interrupt()
            return
        }
        guard let connectionID, let kill = dialect.killSQL(connectionID, connection: false) else {
            throw DatabaseError(message: "The server did not say which connection to stop.")
        }
        var killer = details
        killer.database = ""
        let other = try await DatabaseClient.connect(killer)
        do {
            _ = try await other.run(kill)
        } catch {
            await other.close()
            throw error
        }
        await other.close()
    }

    /// The server's error when a statement was stopped with KILL QUERY.
    public static let queryInterruptedCode = 1317

    // MARK: View Using Encoding (S-056)

    /// The character set this connection reads text in; utf8mb4 from the start.
    public private(set) var viewEncoding: ViewEncoding = .utf8mb4

    /// SET NAMES for `encoding`, then reads every later result with it.
    public func setViewEncoding(_ encoding: ViewEncoding) async throws {
        await acquire()
        defer { release() }
        if let sql = dialect.viewEncodingSQL(encoding) { _ = try await perform(sql, countingRows: false) }
        viewEncoding = encoding
    }

    // MARK: Running SQL

    /// Runs one statement. Statements that return no rows report affected rows.
    public func run(_ sql: String) async throws -> StatementResult {
        await acquire()
        defer { release() }
        return try await perform(sql)
    }

    /// Runs one statement while the caller already holds the connection
    /// (`acquire`), so a multi-statement job such as Rename Database keeps
    /// its `USE` and session variables to itself.
    /// `countingRows: false` skips the affected-rows round trip, for an import's many statements.
    func perform(_ sql: String, countingRows: Bool = true) async throws -> StatementResult {
        if let problem = viewEncoding.problem(sending: sql) {
            throw DatabaseError(message: problem, suggestion: "Choose Database > View Using Encoding > UTF-8 Full Unicode first.")
        }
        let clock = ContinuousClock()
        let start = clock.now
        log(sql)
        do {
            let (columns, rows) = try await driver.execute(sql, encoding: viewEncoding)
            noteDatabase(after: sql)
            var affected: Int?
            if countingRows, rows.isEmpty, !Self.returnsRows(sql) {
                affected = try await driver.affectedRows()
            }
            return StatementResult(sql: sql, columns: columns, rows: rows, affectedRows: affected,
                                   duration: clock.now - start)
        } catch {
            throw logged(failure(error))
        }
    }

    /// Runs an INSERT and returns the auto_increment value it made (0 when none).
    /// Both statements hold the connection, so no other insert can change the id between them.
    public func insert(_ sql: String) async throws -> UInt64 {
        await acquire()
        defer { release() }
        log(sql)
        do {
            _ = try await driver.execute(sql, encoding: viewEncoding)
            return try await driver.lastInsertID()
        } catch {
            throw logged(failure(error))
        }
    }

    // MARK: Console (S-039)

    /// The connection's name in the Console: the saved name, else the host.
    public nonisolated var consoleName: String { details.displayName }

    func log(_ sql: String) {
        console.add(connection: consoleName, database: selectedDatabase, text: ConsoleMessage.statementText(sql))
    }

    func logged(_ error: DatabaseError) -> DatabaseError {
        console.add(connection: consoleName, database: selectedDatabase, text: ConsoleMessage.errorText(error), isError: true)
        return error
    }

    /// A USE that worked changes the database later lines show.
    private func noteDatabase(after sql: String) {
        if let name = Self.usedDatabase(sql) { selectedDatabase = name }
    }

    /// The database a USE statement names, unquoted; nil for any other statement.
    public static func usedDatabase(_ sql: String) -> String? {
        var text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") { text.removeLast() }
        guard text.count > 4, text.prefix(3).uppercased() == "USE", text.dropFirst(3).first?.isWhitespace == true else { return nil }
        let name = text.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("`"), name.hasSuffix("`"), name.count >= 2 {
            return String(name.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`")
        }
        return name.isEmpty ? nil : name
    }

    /// True for statements that answer with rows, even when there are none.
    public static func returnsRows(_ sql: String) -> Bool {
        let first = sql.drop { $0.isWhitespace || $0 == "(" }.prefix { $0.isLetter }.uppercased()
        return ["SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "WITH", "VALUES", "TABLE", "HELP", "CHECK",
                "ANALYZE", "OPTIMIZE", "REPAIR", "CHECKSUM"].contains(first)
    }

    // MARK: Schema (asks the dialect, S-067)

    /// Runs the dialect's statements on this connection, one at a time.
    private var runner: SQLRunner { { [self] sql in try await self.run(sql) } }

    public func databases() async throws -> [String] {
        try await dialect.databases(runner)
    }

    public func use(_ database: String) async throws {
        if let use = dialect.useSQL(database) { _ = try await run(use) }
    }

    /// The database in use on this connection, or nil.
    public func currentDatabase() async throws -> String? {
        try await run(dialect.currentDatabaseSQL).rows.first?.first?.plainText
    }

    /// Tables, views and routines, sorted for the sidebar.
    public func objects(in database: String) async throws -> [DBObject] {
        DBObject.sorted(try await tablesAndViews(in: database) + routines(in: database))
    }

    public func tablesAndViews(in database: String) async throws -> [DBObject] {
        try await dialect.tablesAndViews(in: database, runner)
    }

    /// Procedures and functions. Can fail on its own (MySQL's `mysql.proc`), so
    /// callers load it apart from the tables.
    public func routines(in database: String) async throws -> [DBObject] {
        try await dialect.routines(in: database, runner)
    }

    public func fields(of table: String, in database: String) async throws -> [FieldInfo] {
        try await dialect.fields(of: table, in: database, runner)
    }

    public func indexes(of table: String, in database: String) async throws -> StatementResult {
        try await dialect.indexes(of: table, in: database, runner)
    }

    public func foreignKeys(of table: String, in database: String) async throws -> [ForeignKeyInfo] {
        try await dialect.foreignKeys(of: table, in: database, runner)
    }

    /// Each base table's engine in a database ("InnoDB", "MyISAM"), for Foreign Keys (S-025).
    public func tableEngines(in database: String) async throws -> [String: String] {
        try await dialect.tableEngines(in: database, runner)
    }

    /// The server's explanation of the last foreign key it refused, or nil.
    public func latestForeignKeyError() async -> String? {
        await dialect.latestForeignKeyError(runner)
    }

    public func triggers(of table: String, in database: String) async throws -> StatementResult {
        try await dialect.triggers(of: table, in: database, runner)
    }

    /// Every trigger's name in the database: names are unique there, not per table (S-026).
    public func triggerNames(in database: String) async throws -> [String] {
        try await dialect.triggerNames(in: database, runner)
    }

    public func tableStatus(of table: String, in database: String) async throws -> StatementResult {
        try await dialect.tableStatus(of: table, in: database, runner)
    }

    /// The CREATE statement for any object.
    public func createStatement(of object: DBObject, in database: String) async throws -> String {
        try await dialect.createStatement(of: object, in: database, runner)
    }

    /// `name`'s CREATE statement for a kind from `objectKindSQL` or "event", or nil (agents' create_statement).
    public func createStatement(kind: String, of name: String, in database: String) async throws -> String? {
        try await dialect.createStatement(kind: kind, of: name, in: database, runner)
    }

    /// Rows in `table`, or only those matching `condition` (a WHERE clause without the keyword).
    public func rowCount(of table: String, in database: String, where condition: String? = nil) async throws -> Int {
        let result = try await run(dialect.countSQL(table: table, database: database, where: condition))
        return result.rows.first?.first?.plainText.flatMap(Int.init) ?? 0
    }

    /// One page of rows, filtered by `condition` and sorted on the server.
    /// With `rowID` (SQLite, S-069) the first column is each row's rowid.
    public func page(of table: String, in database: String, where condition: String? = nil, orderBy column: String?,
                     ascending: Bool, offset: Int, limit: Int, rowID: String? = nil) async throws -> StatementResult {
        try await run(dialect.pageSQL(table: table, database: database, where: condition, orderBy: column,
                                      ascending: ascending, offset: offset, limit: limit, rowID: rowID))
    }

    // MARK: One query at a time

    func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

extension ObjectKind {
    var sortOrder: Int {
        switch self {
        case .table: 0
        case .view: 1
        case .procedure: 2
        case .function: 3
        }
    }
}
