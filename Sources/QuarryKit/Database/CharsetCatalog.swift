import Foundation

/// One character set the server offers, as in information_schema.CHARACTER_SETS.
public struct ServerCharset: Sendable, Equatable, Hashable {
    public var name: String
    public var description: String
    /// The collation a database gets when it names this character set and no collation.
    public var defaultCollation: String

    public init(name: String, description: String, defaultCollation: String) {
        self.name = name
        self.description = description
        self.defaultCollation = defaultCollation
    }

    /// "UTF-8 Unicode (utf8mb4)", or the name alone when there is no description.
    public var title: String { description.isEmpty ? name : "\(description) (\(name))" }
}

/// The server's character sets and collations, for the New Database sheet
/// (S-018) and later the table and field sheets. `nil` for a character set
/// or collation means the default: the server's, or the character set's.
public struct CharsetCatalog: Sendable, Equatable {
    public var charsets: [ServerCharset]
    /// Collation names by character set, sorted.
    public var collations: [String: [String]]
    public var serverCharset: String
    public var serverCollation: String

    public init(charsets: [ServerCharset], collations: [(collation: String, charset: String)],
                serverCharset: String, serverCollation: String) {
        self.charsets = Self.ordered(charsets)
        var byCharset: [String: Set<String>] = [:]
        for pair in collations { byCharset[pair.charset, default: []].insert(pair.collation) }
        self.collations = byCharset.mapValues { $0.sorted() }
        self.serverCharset = serverCharset
        self.serverCollation = serverCollation
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.charsets == rhs.charsets && lhs.collations == rhs.collations
            && lhs.serverCharset == rhs.serverCharset && lhs.serverCollation == rhs.serverCollation
    }

    /// The UTF-8 character sets first (utf8mb4, then utf8mb3 or utf8), then
    /// the rest by name, as Sequel Pro promoted UTF-8 to the top of its menu.
    public static func ordered(_ charsets: [ServerCharset]) -> [ServerCharset] {
        func rank(_ name: String) -> Int {
            switch name {
            case "utf8mb4": 0
            case "utf8mb3", "utf8": 1
            default: 2
            }
        }
        return charsets.sorted { (rank($0.name), $0.name) < (rank($1.name), $1.name) }
    }

    /// How many entries at the top of `charsets` are UTF-8, for the menu's divider.
    public var utf8Count: Int { charsets.prefix { $0.name.hasPrefix("utf8") }.count }

    public func charset(named name: String) -> ServerCharset? { charsets.first { $0.name == name } }

    /// The collations that go with a character set; nil means the server's.
    public func collations(for charset: String?) -> [String] {
        collations[charset ?? serverCharset] ?? []
    }

    /// What a database gets with this character set and no collation:
    /// the server's collation when the character set is left to the server too.
    public func defaultCollation(for charset: String?) -> String {
        guard let charset else { return serverCollation }
        return self.charset(named: charset)?.defaultCollation ?? ""
    }
}

/// CREATE DATABASE with an optional character set and collation (S-018).
public struct NewDatabase: Sendable, Equatable {
    public var name: String
    public var charset: String?
    public var collation: String?

    public init(name: String, charset: String? = nil, collation: String? = nil) {
        self.name = name
        self.charset = charset
        self.collation = collation
    }

    public var sql: String {
        var sql = "CREATE DATABASE " + SQLQuote.identifier(name)
        if let charset { sql += " CHARACTER SET " + SQLQuote.identifier(charset) }
        if let collation { sql += " COLLATE " + SQLQuote.identifier(collation) }
        return sql
    }

    /// Why a name cannot be used, or nil. An empty name has no message; it only disables Create.
    public static func problem(with name: String, existing: [String]) -> String? {
        SchemaName.problem(with: name, noun: "database", existing: existing, taken: "A database")
    }
}

extension DatabaseClient {
    /// The server's character sets and collations, and its defaults.
    /// MariaDB 10.10+ lists a collation such as uca1400_ai_ci once for many
    /// character sets, with its full names in FULL_COLLATION_NAME.
    public func charsetCatalog() async throws -> CharsetCatalog {
        let sets = try await run(
            "SELECT CHARACTER_SET_NAME AS name, DESCRIPTION AS description, DEFAULT_COLLATE_NAME AS co "
                + "FROM information_schema.CHARACTER_SETS")
        let pairs = try await run("SELECT * FROM information_schema.COLLATION_CHARACTER_SET_APPLICABILITY")
        let server = try await run("SELECT @@character_set_server AS cs, @@collation_server AS co")
        let charsets = sets.rows.indices.compactMap { row -> ServerCharset? in
            guard let name = sets.string(row, "name") else { return nil }
            return ServerCharset(name: name, description: sets.string(row, "description") ?? "",
                                 defaultCollation: sets.string(row, "co") ?? "")
        }
        let collations = pairs.rows.indices.compactMap { row -> (collation: String, charset: String)? in
            guard let charset = pairs.string(row, "CHARACTER_SET_NAME"),
                  let collation = pairs.string(row, "FULL_COLLATION_NAME") ?? pairs.string(row, "COLLATION_NAME")
            else { return nil }
            return (collation, charset)
        }
        return CharsetCatalog(charsets: charsets, collations: collations,
                              serverCharset: server.string(0, "cs") ?? "", serverCollation: server.string(0, "co") ?? "")
    }

    public func create(_ database: NewDatabase) async throws {
        _ = try await run(database.sql)
    }
}
