import Foundation

/// CREATE TABLE with one field, `id`, and an optional engine, character set
/// and collation (S-021), as Sequel Pro's Add Table made it. `nil` means the
/// database's default, so the statement leaves it out.
public struct NewTable: Sendable, Equatable {
    public var name: String
    public var engine: String?
    public var charset: String?
    public var collation: String?

    public init(name: String, engine: String? = nil, charset: String? = nil, collation: String? = nil) {
        self.name = name
        self.engine = engine
        self.charset = charset
        self.collation = collation
    }

    /// The CSV engine allows no indexes, so its `id` is a plain NOT NULL field.
    public var sql: String { sql(for: .mysql) }

    /// A SQLite table starts with `id INTEGER PRIMARY KEY`, the rowid (S-070).
    public func sql(for databaseEngine: Engine) -> String {
        if databaseEngine == .sqlite { return "CREATE TABLE " + SQLiteTable.quote(name) + " (\"id\" INTEGER PRIMARY KEY)" }
        var id = "`id` INT UNSIGNED NOT NULL"
        if engine?.uppercased() != "CSV" { id += " AUTO_INCREMENT PRIMARY KEY" }
        var sql = "CREATE TABLE " + SQLQuote.identifier(name) + " (" + id + ")"
        if let engine { sql += " ENGINE = " + SQLQuote.identifier(engine) }
        if let charset { sql += " DEFAULT CHARACTER SET " + SQLQuote.identifier(charset) }
        if let collation { sql += " COLLATE " + SQLQuote.identifier(collation) }
        return sql
    }

    /// Why a name cannot be used, or nil. Tables and views share one namespace,
    /// so `existing` holds both.
    public static func problem(with name: String, existing: [String]) -> String? {
        SchemaName.problem(with: name, noun: "table", existing: existing, taken: "A table or view")
    }
}

/// The name rules for databases and tables: up to 64 characters, not only
/// spaces, no trailing space, not taken (ignoring case).
public enum SchemaName {
    public static func problem(with name: String, noun: String, existing: [String], taken: String) -> String? {
        if name.isEmpty { return nil }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "A \(noun) name can’t be only spaces." }
        if name.last?.isWhitespace == true { return "A \(noun) name can’t end with a space." }
        if name.count > 64 { return "A \(noun) name can be at most 64 characters." }
        if existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return "\(taken) named “\(name)” already exists."
        }
        return nil
    }
}

/// What a new table gets when the sheet leaves a menu on its default.
public struct TableDefaults: Sendable, Equatable {
    /// Engines the server supports, by name; PERFORMANCE_SCHEMA left out.
    public var engines: [String]
    public var defaultEngine: String
    public var charset: String
    public var collation: String

    public init(engines: [String], defaultEngine: String, charset: String, collation: String) {
        self.engines = engines.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        self.defaultEngine = defaultEngine
        self.charset = charset
        self.collation = collation
    }
}

extension DatabaseClient {
    /// The supported engines and the database's character set and collation.
    public func tableDefaults(in database: String) async throws -> TableDefaults {
        let engines = try await run(
            "SELECT ENGINE AS engine, SUPPORT AS support FROM information_schema.ENGINES "
                + "WHERE SUPPORT IN ('DEFAULT', 'YES') AND ENGINE <> 'PERFORMANCE_SCHEMA'")
        let schema = try await run(
            "SELECT DEFAULT_CHARACTER_SET_NAME AS cs, DEFAULT_COLLATION_NAME AS co FROM information_schema.SCHEMATA "
                + "WHERE SCHEMA_NAME = " + SQLQuote.mysqlLiteral(database))
        let names = engines.rows.indices.compactMap { engines.string($0, "engine") }
        let flagged = engines.rows.indices.first { engines.string($0, "support") == "DEFAULT" }
        return TableDefaults(engines: names, defaultEngine: flagged.flatMap { engines.string($0, "engine") } ?? "",
                             charset: schema.string(0, "cs") ?? "", collation: schema.string(0, "co") ?? "")
    }

    public func create(_ table: NewTable) async throws {
        _ = try await run(table.sql(for: dialect.engine))
    }
}
