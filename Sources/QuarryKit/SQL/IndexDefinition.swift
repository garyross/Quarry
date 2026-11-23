import Foundation

/// The kinds of index Add Index offers (S-024), in its menu's order.
public enum IndexKind: String, Sendable, CaseIterable {
    case index, unique, primary, fullText, spatial

    public var title: String {
        switch self {
        case .index: "Index"
        case .unique: "Unique"
        case .primary: "Primary Key"
        case .fullText: "Full Text"
        case .spatial: "Spatial"
        }
    }

    /// The words after ADD.
    var keyword: String {
        switch self {
        case .index: "INDEX"
        case .unique: "UNIQUE INDEX"
        case .primary: "PRIMARY KEY"
        case .fullText: "FULLTEXT INDEX"
        case .spatial: "SPATIAL INDEX"
        }
    }

    /// Full Text and Spatial indexes hold whole values and have their own storage.
    public var takesPrefix: Bool { self != .fullText && self != .spatial }
    public var takesStorage: Bool { takesPrefix }
}

/// BTREE or HASH, or the engine's default.
public enum IndexStorage: String, Sendable, CaseIterable {
    case `default`, btree, hash

    public var title: String {
        switch self {
        case .default: "Default"
        case .btree: "BTREE"
        case .hash: "HASH"
        }
    }
}

/// When a field's index needs a prefix length.
public enum PrefixRule: Sendable, Equatable {
    case none, optional, required

    /// Text and Blob need one (except in a Full Text index); String and Binary may have one.
    public static func of(type: String, kind: IndexKind) -> PrefixRule {
        guard kind.takesPrefix else { return .none }
        switch TypeFamily(type: type) {
        case .text, .blob: return .required
        case .string, .binary: return .optional
        default: return .none
        }
    }
}

/// One field of an index, with its prefix length.
public struct IndexPart: Sendable, Hashable {
    public var field: String
    public var prefix: Int?

    public init(field: String, prefix: Int? = nil) {
        self.field = field
        self.prefix = prefix
    }
}

/// An index to add.
public struct IndexDefinition: Sendable, Hashable {
    public var kind: IndexKind
    /// Empty lets the server name it (a primary key is always PRIMARY).
    public var name: String
    public var parts: [IndexPart]
    public var storage: IndexStorage
    public var keyBlockSize: Int?
    public var comment: String

    public init(kind: IndexKind = .index, name: String = "", parts: [IndexPart], storage: IndexStorage = .default,
                keyBlockSize: Int? = nil, comment: String = "") {
        self.kind = kind
        self.name = name
        self.parts = parts
        self.storage = storage
        self.keyBlockSize = keyBlockSize
        self.comment = comment
    }
}

/// An index as SHOW INDEX lists it: one entry per index, its fields in order.
public struct IndexSummary: Sendable, Hashable {
    public var name: String
    public var fields: [String]
    public var isPrimary: Bool { name == "PRIMARY" }

    public init(name: String, fields: [String]) {
        self.name = name
        self.fields = fields
    }

    /// Groups SHOW INDEX's rows (one per field) into indexes, in the order listed.
    public static func group(names: [String], fields: [String]) -> [IndexSummary] {
        var result: [IndexSummary] = []
        for (name, field) in zip(names, fields) {
            if let at = result.firstIndex(where: { $0.name == name }) {
                result[at].fields.append(field)
            } else {
                result.append(IndexSummary(name: name, fields: [field]))
            }
        }
        return result
    }
}

public enum IndexChange {
    /// `ALTER TABLE … ADD [kind] [name] [USING storage] (field(prefix), …) [KEY_BLOCK_SIZE = n] [COMMENT '…']`.
    public static func addSQL(_ index: IndexDefinition, to table: String, in database: String) -> String {
        var sql = "ALTER TABLE " + SQLQuote.qualified(database, table) + " ADD " + index.kind.keyword
        let name = index.name.trimmingCharacters(in: .whitespaces)
        if index.kind != .primary, !name.isEmpty { sql += " " + SQLQuote.identifier(name) }
        if index.kind.takesStorage, index.storage != .default { sql += " USING " + index.storage.title }
        let parts = index.parts.map { part in
            var text = SQLQuote.identifier(part.field)
            if index.kind.takesPrefix, let prefix = part.prefix, prefix > 0 { text += "(\(prefix))" }
            return text
        }
        sql += " (" + parts.joined(separator: ", ") + ")"
        if let size = index.keyBlockSize, size > 0 { sql += " KEY_BLOCK_SIZE = \(size)" }
        if !index.comment.isEmpty { sql += " COMMENT " + SQLQuote.mysqlLiteral(index.comment) }
        return sql
    }

    /// SQLite's CREATE [UNIQUE] INDEX (S-070): a name is needed, so an empty one becomes table_field_field.
    public static func sqliteAddSQL(_ index: IndexDefinition, to table: String) -> String {
        var name = index.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = ([table] + index.parts.map(\.field)).joined(separator: "_") }
        return "CREATE " + (index.kind == .unique ? "UNIQUE " : "") + "INDEX " + SQLiteTable.quote(name) + " ON "
            + SQLiteTable.quote(table) + " (" + index.parts.map { SQLiteTable.quote($0.field) }.joined(separator: ", ") + ")"
    }

    /// One DROP INDEX per index: SQLite drops one at a time.
    public static func sqliteDropSQL(_ names: [String]) -> [String] {
        names.map { "DROP INDEX " + SQLiteTable.quote($0) }
    }

    /// The primary key and the indexes SQLite makes for UNIQUE constraints go only with a rebuild.
    public static func sqliteCanDrop(_ name: String) -> Bool {
        name != "PRIMARY" && !name.lowercased().hasPrefix("sqlite_autoindex_")
    }

    /// One ALTER TABLE that drops every named index (PRIMARY as DROP PRIMARY KEY).
    public static func dropSQL(_ names: [String], from table: String, in database: String) -> String {
        "ALTER TABLE " + SQLQuote.qualified(database, table) + " "
            + names.map { $0 == "PRIMARY" ? "DROP PRIMARY KEY" : "DROP INDEX " + SQLQuote.identifier($0) }
                .joined(separator: ", ")
    }

    /// Why a name can't be used, or nil. Names compare without case, as the server does.
    public static func nameProblem(_ name: String, existing: [String]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.uppercased() == "PRIMARY" { return "Only the primary key is named PRIMARY." }
        if trimmed.count > 64 { return "An index name can be at most 64 characters." }
        if existing.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "An index named \u{201C}\(trimmed)\u{201D} already exists."
        }
        return nil
    }
}
