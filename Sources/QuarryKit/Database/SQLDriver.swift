import Foundation

/// The wire to one engine (S-067): runs statements and turns their answers
/// into `ResultColumn` and `CellValue`. `DatabaseClient` owns one and adds what
/// every engine shares: one statement at a time, the Console, lost connections.
/// `MySQLDriver` talks to MySQL and MariaDB; a SQLite driver comes with S-068.
protocol SQLDriver: Sendable {
    /// "11.4.2-MariaDB" or "8.4.2", as the server reports it.
    var serverVersion: String { get }
    /// The server's id for this connection, for KILL QUERY (S-036); nil when there is none.
    var connectionID: Int? { get }
    /// How the connection is encrypted; nil without SSL (S-058).
    var encryption: Encryption? { get }
    var isClosed: Bool { get }

    /// Runs one statement and returns every row.
    func execute(_ sql: String, encoding: ViewEncoding) async throws -> (columns: [ResultColumn], rows: [[CellValue]])
    /// Runs one statement and hands over each row as it arrives. Columns and
    /// cells are decoded only when asked, so rows nobody keeps cost little.
    func stream(_ sql: String, encoding: ViewEncoding,
                row: @escaping @Sendable (_ columns: () -> [ResultColumn], _ cells: () -> [CellValue]) -> Void) async throws
    /// Rows the last statement changed.
    func affectedRows() async throws -> Int
    /// The auto-increment value the last INSERT made, 0 when none.
    func lastInsertID() async throws -> UInt64
    /// A round trip that keeps an idle connection open.
    func ping() async throws
    func close() async
    /// Whether an error means the connection itself is gone, not just the statement.
    func isLost(_ error: any Error) -> Bool
    /// The error in words people can act on.
    func describe(_ error: any Error) -> DatabaseError
}
