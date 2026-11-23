import Foundation

/// What a foreign key does to its rows when the referenced row changes or goes (S-025).
public enum ForeignKeyAction: String, Sendable, CaseIterable {
    case restrict, cascade, setNull, noAction

    public var title: String {
        switch self {
        case .restrict: "Restrict"
        case .cascade: "Cascade"
        case .setNull: "Set NULL"
        case .noAction: "No Action"
        }
    }

    public var sql: String {
        switch self {
        case .restrict: "RESTRICT"
        case .cascade: "CASCADE"
        case .setNull: "SET NULL"
        case .noAction: "NO ACTION"
        }
    }
}

/// A foreign key to add: one field pointing at one field of a table in the same database.
public struct ForeignKeyDefinition: Sendable, Hashable {
    /// Empty lets the server name it.
    public var name: String
    public var field: String
    public var referencedTable: String
    public var referencedField: String
    public var onUpdate: ForeignKeyAction
    public var onDelete: ForeignKeyAction

    public init(name: String = "", field: String, referencedTable: String, referencedField: String,
                onUpdate: ForeignKeyAction = .restrict, onDelete: ForeignKeyAction = .restrict) {
        self.name = name
        self.field = field
        self.referencedTable = referencedTable
        self.referencedField = referencedField
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }
}

public enum ForeignKeyChange {
    /// `ALTER TABLE … ADD [CONSTRAINT name] FOREIGN KEY (field) REFERENCES table (field) ON DELETE … ON UPDATE …`.
    public static func addSQL(_ key: ForeignKeyDefinition, to table: String, in database: String) -> String {
        var sql = "ALTER TABLE " + SQLQuote.qualified(database, table) + " ADD "
        let name = key.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { sql += "CONSTRAINT " + SQLQuote.identifier(name) + " " }
        sql += "FOREIGN KEY (" + SQLQuote.identifier(key.field) + ") REFERENCES "
            + SQLQuote.qualified(database, key.referencedTable) + " (" + SQLQuote.identifier(key.referencedField) + ")"
        sql += " ON DELETE " + key.onDelete.sql + " ON UPDATE " + key.onUpdate.sql
        return sql
    }

    /// One ALTER TABLE that drops every named foreign key.
    public static func dropSQL(_ names: [String], from table: String, in database: String) -> String {
        "ALTER TABLE " + SQLQuote.qualified(database, table) + " "
            + names.map { "DROP FOREIGN KEY " + SQLQuote.identifier($0) }.joined(separator: ", ")
    }

    /// Why a name can't be used, or nil. Names compare without case, as the server does.
    public static func nameProblem(_ name: String, existing: [String]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.count > 64 { return "A foreign key name can be at most 64 characters." }
        if existing.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "A foreign key named \u{201C}\(trimmed)\u{201D} already exists."
        }
        return nil
    }

    /// Whether a field can be in a foreign key: not Text, Blob, JSON, Spatial or a generated field.
    public static func canBeKeyed(_ field: FieldDefinition) -> Bool {
        guard !field.isGenerated else { return false }
        switch field.family {
        case .text, .blob, .json, .spatial: return false
        default: return true
        }
    }

    /// InnoDB's rule for a field and the field it references: the same integer type and sign,
    /// the same decimal size, char or varchar (or binary or varbinary) with the same collation,
    /// and otherwise the very same type.
    public static func isCompatible(_ field: FieldDefinition, with referenced: FieldDefinition) -> Bool {
        guard canBeKeyed(field), canBeKeyed(referenced), field.family == referenced.family else { return false }
        switch field.family {
        case .integer:
            return field.type == referenced.type && field.isUnsigned == referenced.isUnsigned
        case .decimal:
            return field.type == referenced.type && field.isUnsigned == referenced.isUnsigned
                && (field.type != "decimal" || lengthsMatch(field.length, referenced.length))
        case .string:
            return collation(field) == collation(referenced)
        case .binary:
            return true
        default:
            return field.type == referenced.type && field.length == referenced.length
        }
    }

    /// The fields of `table` a foreign key from `field` can point at: compatible, and first in one of its indexes.
    public static func referenceable(from field: FieldDefinition, among fields: [FieldDefinition],
                                     indexes: [IndexSummary]) -> [String] {
        let leading = Set(indexes.compactMap(\.fields.first))
        return fields.filter { leading.contains($0.name) && isCompatible(field, with: $0) }.map(\.name)
    }

    /// The table a field's name points at: "customer_id" -> customers, "category" -> categories.
    public static func guessTable(for field: String, among tables: [String]) -> String? {
        let lower = field.lowercased()
        let base = lower.hasSuffix("_id") ? String(lower.dropLast(3)) : lower.hasSuffix("id") ? String(lower.dropLast(2)) : lower
        guard !base.isEmpty else { return nil }
        let names = [base, base + "s", base + "es", base.hasSuffix("y") ? String(base.dropLast()) + "ies" : base]
        for name in names {
            if let table = tables.first(where: { $0.lowercased() == name }) { return table }
        }
        return nil
    }

    /// DECIMAL(10) is DECIMAL(10,0); an empty length is the server's default.
    private static func lengthsMatch(_ lhs: String, _ rhs: String) -> Bool {
        func normal(_ text: String) -> [Int] {
            var parts = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.isEmpty { parts = [10] }
            if parts.count == 1 { parts.append(0) }
            return parts
        }
        return normal(lhs) == normal(rhs)
    }

    private static func collation(_ field: FieldDefinition) -> String? { field.collation?.lowercased() }
}

/// Reads SHOW ENGINE INNODB STATUS.
public enum InnoDBStatus {
    /// The LATEST FOREIGN KEY ERROR section's text on one line, without its timestamp, or nil.
    public static func latestForeignKeyError(_ status: String) -> String? {
        let lines = status.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "LATEST FOREIGN KEY ERROR" })
        else { return nil }
        func isRule(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count >= 3 && trimmed.allSatisfy { $0 == "-" }
        }
        var body: [String] = []
        var index = start + 1
        while index < lines.count, isRule(lines[index]) { index += 1 }
        while index < lines.count, !isRule(lines[index]) {
            body.append(lines[index].trimmingCharacters(in: .whitespaces))
            index += 1
        }
        // The first line starts with a date and time and a thread id: "2026-11-18 10:12:01 0x7f… Error in…".
        if var first = body.first {
            if let range = first.range(of: #"^\d{4}-\d{2}-\d{2} [0-9:]+ (0x[0-9a-f]+ )?"#, options: .regularExpression) {
                first.removeSubrange(range)
            }
            body[0] = first
        }
        let text = body.filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}
