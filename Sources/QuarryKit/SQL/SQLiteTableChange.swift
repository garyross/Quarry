import Foundation

/// A change to a SQLite table's fields or foreign keys (S-070). SQLite's ALTER
/// TABLE adds, renames and drops columns; everything else is a table rebuild:
/// a new table, the rows copied, the old one dropped and the new one renamed,
/// in one transaction (`DatabaseClient.applySQLite`).
public enum SQLiteTableChange: Sendable, Equatable {
    /// The field named `String` becomes the definition, moved to the position.
    case edit(String, FieldDefinition, FieldPosition)
    case add(FieldDefinition, FieldPosition)
    case drop([String])
    case addForeignKey(ForeignKeyDefinition)
    /// PRAGMA foreign_key_list's ids.
    case dropForeignKeys([Int])
}

/// What a change runs: ALTER TABLE statements, then, when SQLite can't make the change in place, a rebuild.
public struct SQLiteChangePlan: Sendable, Equatable {
    public var table: String
    /// Run first, in the transaction: RENAME COLUMN, ADD COLUMN, DROP COLUMN.
    public var statements: [String]
    /// The table as the rebuild makes it, or nil when the statements are the whole change.
    public var rebuild: SQLiteTable?
    /// The fields the rebuild copies, by their names after the statements.
    public var copied: [String]

    public var needsRebuild: Bool { rebuild != nil }

    /// The name the new table has until the old one is gone.
    public var temporaryName: String { "quarry_new_" + table }

    /// The statements in the order they run, for the sheet's footer and the tests;
    /// the indexes and triggers the rebuild puts back are read from the file when it runs.
    public var script: [String] {
        guard let rebuild else { return statements }
        let columns = copied.map(SQLiteTable.quote).joined(separator: ", ")
        var steps = statements + [rebuild.createSQL(named: temporaryName)]
        if !copied.isEmpty {
            steps.append("INSERT INTO \(SQLiteTable.quote(temporaryName)) (\(columns)) SELECT \(columns) FROM \(SQLiteTable.quote(table))")
        }
        if rebuild.columns.contains(where: \.isAutoIncrement) {
            // AUTOINCREMENT never reuses a number the old table gave out, even for rows since deleted.
            let old = "(SELECT seq FROM sqlite_sequence WHERE name = \(SQLQuote.literal(table, engine: .sqlite)))"
            steps.append("UPDATE sqlite_sequence SET seq = max(seq, \(old)) WHERE name = "
                + SQLQuote.literal(temporaryName, engine: .sqlite) + " AND \(old) IS NOT NULL")
        }
        steps += ["DROP TABLE " + SQLiteTable.quote(table),
                  "PRAGMA legacy_alter_table = ON",
                  "ALTER TABLE \(SQLiteTable.quote(temporaryName)) RENAME TO \(SQLiteTable.quote(table))",
                  "PRAGMA legacy_alter_table = OFF"]
        return steps
    }

    /// What the sheet shows under its fields: the ALTER TABLE, or the new CREATE TABLE.
    public var summary: String {
        guard let rebuild else { return statements.joined(separator: ";\n") }
        return "Rebuilds the table:\n" + rebuild.createSQL(named: table)
    }
}

extension SQLiteTableChange {
    /// The plan for this change to `table`, whose CREATE TABLE is `create` and whose fields are `fields`, in order.
    public func plan(table name: String, create: SQLiteTable, fields: [FieldDefinition]) throws -> SQLiteChangePlan {
        let alter = "ALTER TABLE " + SQLiteTable.quote(name)
        var plan = SQLiteChangePlan(table: name, statements: [], rebuild: nil, copied: [])
        var table = create
        switch self {
        case .edit(let oldName, let field, let position):
            guard let index = table.column(named: oldName), let old = fields.first(where: { $0.name == oldName }) else {
                throw DatabaseError(message: "The field “\(oldName)” is no longer in the table.")
            }
            if field.name != oldName {
                plan.statements.append(alter + " RENAME COLUMN " + SQLiteTable.quote(oldName) + " TO " + SQLiteTable.quote(field.name))
                table.columns[index].name = field.name
            }
            var unnamed = field
            unnamed.name = oldName
            guard unnamed != old || position != .unchanged else { return plan }
            table.columns[index] = Self.column(field, from: table.columns[index], old: old)
            if field.extra == .autoIncrement, old.extra != .autoIncrement {
                table.constraints.removeAll { $0.kind == "PRIMARY" && $0.keyColumns == [oldName.lowercased()] }
            }
            if position != .unchanged { table.columns = try Self.moving(index, to: position, in: table.columns) }
            plan.copied = table.columns.filter { !$0.isGenerated }.map(\.name)
            plan.rebuild = table
        case .add(let field, let position):
            let column = Self.column(field, from: nil, old: nil)
            let atEnd: Bool
            switch position {
            case .unchanged: atEnd = true
            case .first: atEnd = false
            case .after(let other): atEnd = other.caseInsensitiveCompare(table.columns.last?.name ?? "") == .orderedSame
            }
            if atEnd, Self.canAddInPlace(column) {
                plan.statements.append(alter + " ADD COLUMN " + column.sql)
                return plan
            }
            plan.copied = table.columns.filter { !$0.isGenerated }.map(\.name)
            table.columns.append(column)
            if !atEnd { table.columns = try Self.moving(table.columns.count - 1, to: position, in: table.columns) }
            plan.rebuild = table
        case .drop(let names):
            plan.statements = names.map { alter + " DROP COLUMN " + SQLiteTable.quote($0) }
        case .addForeignKey(let key):
            var clause = "FOREIGN KEY (\(SQLiteTable.quote(key.field))) REFERENCES \(SQLiteTable.quote(key.referencedTable)) "
                + "(\(SQLiteTable.quote(key.referencedField)))"
            if key.onDelete != .noAction { clause += " ON DELETE " + key.onDelete.sql }
            if key.onUpdate != .noAction { clause += " ON UPDATE " + key.onUpdate.sql }
            let name = key.name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { clause = "CONSTRAINT " + SQLiteTable.quote(name) + " " + clause }
            table.constraints.append(SQLiteConstraint(text: clause))
            plan.copied = table.columns.filter { !$0.isGenerated }.map(\.name)
            plan.rebuild = table
        case .dropForeignKeys(let ids):
            table = try table.removingForeignKeys(ids: ids)
            plan.copied = table.columns.filter { !$0.isGenerated }.map(\.name)
            plan.rebuild = table
        }
        return plan
    }

    /// ADD COLUMN can't add a key, a UNIQUE or generated stored field, an expression default,
    /// or NOT NULL without a default; nor REFERENCES with a default other than NULL.
    static func canAddInPlace(_ column: SQLiteColumn) -> Bool {
        guard !column.isPrimaryKey, !column.isUnique else { return false }
        let value = column.defaultSQL?.uppercased()
        if let value, value.hasPrefix("(") || value.hasPrefix("CURRENT_") { return false }
        if column.isNotNull, value == nil || value == "NULL" { return false }
        if column.hasReferences, let value, value != "NULL" { return false }
        return true
    }

    static func moving(_ index: Int, to position: FieldPosition, in columns: [SQLiteColumn]) throws -> [SQLiteColumn] {
        var columns = columns
        let column = columns.remove(at: index)
        switch position {
        case .unchanged: columns.insert(column, at: index)
        case .first: columns.insert(column, at: 0)
        case .after(let name):
            guard let other = columns.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw DatabaseError(message: "The field “\(name)” is no longer in the table.")
            }
            columns.insert(column, at: other + 1)
        }
        return columns
    }

    /// `field` as a column: the parts that changed from `old` written anew, the rest of `base` kept as it was.
    public static func column(_ field: FieldDefinition, from base: SQLiteColumn?, old: FieldDefinition?) -> SQLiteColumn {
        var column = base ?? SQLiteColumn(name: field.name, type: "")
        column.name = field.name
        if old == nil || field.type != old?.type { column.type = field.type.uppercased() }
        if old == nil || field.isNullable != old?.isNullable {
            column.setNotNull(!field.isNullable)
        }
        if old == nil || field.defaultValue != old?.defaultValue { column.setDefault(defaultSQL(field.defaultValue)) }
        if old == nil || field.collation != old?.collation { column.setCollation(field.collation) }
        if old == nil ? field.extra == .autoIncrement : field.extra != old?.extra {
            column.setAutoIncrement(field.extra == .autoIncrement)
        }
        return column
    }

    /// A default as SQLite writes it: numbers bare, text quoted, CURRENT_TIMESTAMP as is, any other expression in parentheses.
    public static func defaultSQL(_ value: FieldDefault) -> String? {
        switch value {
        case .none: return nil
        case .null: return "NULL"
        case .value(let text):
            return isNumber(text) ? text : SQLQuote.literal(text, engine: .sqlite)
        case .expression(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let upper = trimmed.uppercased()
            if ["CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME", "NULL", "TRUE", "FALSE"].contains(upper)
                || trimmed.hasPrefix("(") || isNumber(trimmed)
                || trimmed.range(of: #"^([xX]?'([^']|'')*')$"#, options: .regularExpression) != nil {
                return trimmed
            }
            return "(" + trimmed + ")"
        }
    }

    static func isNumber(_ text: String) -> Bool {
        text.range(of: #"^[-+]?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?$"#, options: .regularExpression) != nil
    }

    /// What people type as a SQLite default: empty is none, NULL is NULL, a number, CURRENT_TIMESTAMP,
    /// or a call or expression in parentheses (datetime('now')) is kept as SQL; anything else is text.
    public static func typedDefault(_ text: String) -> FieldDefault {
        if text.isEmpty { return .none }
        if text.uppercased() == "NULL" { return .null }
        if isExpression(text) { return .expression(text) }
        return .value(text)
    }

    /// CURRENT_TIMESTAMP, (1 + 2), datetime('now'), x'00'.
    public static func isExpression(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return ["CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME"].contains(trimmed.uppercased())
            || (trimmed.hasPrefix("(") && trimmed.hasSuffix(")"))
            || trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\s*\(.*\)$"#, options: .regularExpression) != nil
            || trimmed.range(of: #"^[xX]'[0-9a-fA-F]*'$"#, options: .regularExpression) != nil
    }

    /// The types a field can have: a STRICT table's own, else SQLite's usual names.
    public static func types(strict: Bool) -> [String] {
        strict ? ["INT", "INTEGER", "REAL", "TEXT", "BLOB", "ANY"] : ["INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC"]
    }

    /// SQLite's built-in collations.
    public static let collations = ["BINARY", "NOCASE", "RTRIM"]
}

extension FieldDefinition {
    /// A SQLite field from PRAGMA table_info and its column in CREATE TABLE: the type as declared
    /// (no length), AUTOINCREMENT, its collation, and a default that is a call kept as an expression.
    public init(sqlite field: FieldInfo, column: SQLiteColumn?) {
        self.init(name: field.name, type: field.fullType, isNullable: field.isNullable)
        if field.extra == "autoincrement" { extra = .autoIncrement }
        collation = column?.collation ?? field.collation
        if let value = field.defaultValue {
            let quoted = column?.defaultSQL?.hasPrefix("'") == true
            defaultValue = !quoted && SQLiteTableChange.isExpression(value) ? .expression(value) : .value(value)
            if !quoted, value.uppercased() == "NULL" { defaultValue = .null }
        } else {
            defaultValue = field.isNullable ? .null : .none
        }
        isGenerated = column?.isGenerated ?? false
    }
}
