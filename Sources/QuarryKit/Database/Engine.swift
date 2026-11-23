import Foundation

/// Which kind of database a connection opens (M8). MySQL and MariaDB speak
/// the same protocol and SQL; a SQLite file has no server at all.
/// `DatabaseClient.connect` picks the driver and the `SQLDialect` from it.
public enum Engine: String, Sendable, Codable, CaseIterable {
    case mysql
    case sqlite
}

extension ConnectionDetails {
    /// The engine follows Connect With: SQLite File opens a file (S-068),
    /// every other choice reaches a MySQL or MariaDB server.
    public var engine: Engine { transport == .sqlite ? .sqlite : .mysql }
}
