import Foundation

/// Runs one statement on the caller's connection, logged to the Console.
public typealias SQLRunner = @Sendable (String) async throws -> StatementResult

/// What one engine's SQL looks like for the questions Quarry asks about a
/// database (M8, S-067): the statements, and how to read their answers.
/// `DatabaseClient` holds one and passes it a `SQLRunner`; tests pass their own.
///
/// Methods that return SQL text and no parsing promise the column names they
/// answer with (listed on each), so callers read them the same way on every engine.
/// A nil statement means the engine has no such thing (a SQLite file has no processes).
public protocol SQLDialect: Sendable {
    var engine: Engine { get }

    // MARK: Names and quoting

    /// An identifier, quoted: `name`.
    func identifier(_ name: String) -> String
    /// A string literal, quoted and escaped: 'text'.
    func literal(_ text: String) -> String
    /// `database`.`name`.
    func qualified(_ database: String, _ name: String) -> String
    /// Databases the server makes up as it goes (they can't be copied or edited).
    func isInMemory(_ database: String) -> Bool

    // MARK: Catalog

    func databases(_ run: SQLRunner) async throws -> [String]
    /// Switches the connection to `database`; nil when there is only one (a SQLite file).
    func useSQL(_ database: String) -> String?
    /// The statement that answers one row, one column: the database in use, or NULL.
    var currentDatabaseSQL: String { get }
    func tablesAndViews(in database: String, _ run: SQLRunner) async throws -> [DBObject]
    func routines(in database: String, _ run: SQLRunner) async throws -> [DBObject]
    func fields(of table: String, in database: String, _ run: SQLRunner) async throws -> [FieldInfo]
    /// One row per indexed field, with the columns of MySQL's SHOW INDEX
    /// (Key_name, Seq_in_index, Column_name, Non_unique, Sub_part, Index_type, Comment, ...).
    func indexes(of table: String, in database: String, _ run: SQLRunner) async throws -> StatementResult
    func foreignKeys(of table: String, in database: String, _ run: SQLRunner) async throws -> [ForeignKeyInfo]
    /// Each base table's storage engine ("InnoDB"); empty when the engine has none.
    func tableEngines(in database: String, _ run: SQLRunner) async throws -> [String: String]
    /// Why the last foreign key was refused, when the server can say.
    func latestForeignKeyError(_ run: SQLRunner) async -> String?
    /// One row per trigger, with the columns of MySQL's SHOW TRIGGERS (Trigger, Event, Table, Statement, Timing, ...).
    func triggers(of table: String, in database: String, _ run: SQLRunner) async throws -> StatementResult
    func triggerNames(in database: String, _ run: SQLRunner) async throws -> [String]
    /// One row with the columns of MySQL's SHOW TABLE STATUS (Name, Engine, Rows, Data_length, ...).
    func tableStatus(of table: String, in database: String, _ run: SQLRunner) async throws -> StatementResult
    /// The CREATE statement Show Create Statement and Info show; "" when there is none.
    func createStatement(of object: DBObject, in database: String, _ run: SQLRunner) async throws -> String
    /// `name`'s CREATE statement as the engine stores it, for a kind from `objectKindSQL`
    /// or "event"; nil when the engine gave none (no such object, or no permission to see it).
    /// The one read behind `createStatement(of:)` and the agents' create_statement.
    func createStatement(kind: String, of name: String, in database: String, _ run: SQLRunner) async throws -> String?

    // MARK: Rows

    func countSQL(table: String, database: String, where condition: String?) -> String
    /// One page of `table`. With `rowID` (SQLite's rowid, S-069), the first column is the row's rowid,
    /// so a table with no primary key can be edited; engines without one ignore it.
    func pageSQL(table: String, database: String, where condition: String?, orderBy column: String?,
                 ascending: Bool, offset: Int, limit: Int, rowID: String?) -> String
    /// Changes the character set results come back in; nil when the engine always uses UTF-8.
    func viewEncodingSQL(_ encoding: ViewEncoding) -> String?

    // MARK: Export (S-041, S-071)

    /// Starts a transaction in which every later read sees one snapshot of the
    /// database, for an export; COMMIT ends it.
    var snapshotBeginSQL: [String] { get }

    // MARK: Agents (S-063)

    /// Starts a transaction in which the server refuses every write.
    var readOnlyBeginSQL: String { get }
    var rollbackSQL: String { get }
    func explainSQL(_ statement: String) -> String
    func sampleSQL(table: String, database: String, limit: Int) -> String
    /// Columns name, type ("BASE TABLE" or "VIEW"), engine, rows_estimate, comment.
    func agentTablesSQL(in database: String) -> String
    /// Columns name, kind ("PROCEDURE" or "FUNCTION"), returns, comment; nil without routines.
    func agentRoutinesSQL(in database: String) -> String?
    /// Columns name, table, timing, event; SQLite leaves timing and event empty and adds statement, the CREATE TRIGGER.
    func agentTriggersSQL(in database: String) -> String
    /// Columns name, status, type, every, unit; nil without scheduled events.
    func agentEventsSQL(in database: String) -> String?
    /// One column: the object's type ("BASE TABLE", "VIEW"); no row when there is none.
    func objectTypeSQL(of name: String, in database: String) -> String
    /// One column: "table", "view", "procedure", "function" or "trigger"; no row when nothing has the name.
    func objectKindSQL(of name: String, in database: String) -> String
    /// Columns name, engine, rows_estimate, data, idx, free; biggest first.
    func tableSizesSQL(in database: String) -> String
    /// The same columns, for when `tableSizesSQL` fails (a SQLite without dbstat); nil when there is no fallback.
    func tableSizesFallbackSQL(in database: String) -> String?
    /// Columns Variable_name, Value: a file's own settings (S-073); nil on a server, whose settings are variables.
    var fileSettingsSQL: String? { get }

    // MARK: Server

    /// One column: the account the connection logged in as.
    var currentUserSQL: String? { get }
    /// Columns Variable_name, Value.
    func variablesSQL(named names: [String]) -> String?
    /// Columns Variable_name, Value: the server's uptime in seconds.
    var uptimeSQL: String? { get }
    /// The columns of MySQL's SHOW PROCESSLIST.
    func processListSQL(full: Bool) -> String?
    /// Stops process `id`'s statement, or with `connection` the whole connection.
    func killSQL(_ id: Int, connection: Bool) -> String?
}

extension SQLDialect {
    public func tableSizesFallbackSQL(in database: String) -> String? { nil }
    public var fileSettingsSQL: String? { nil }
    public func identifier(_ name: String) -> String { SQLQuote.identifier(name) }
    /// Text quoted as this dialect's engine reads it.
    public func literal(_ text: String) -> String { SQLQuote.literal(text, engine: engine) }
    public func qualified(_ database: String, _ name: String) -> String { SQLQuote.qualified(database, name) }
}
