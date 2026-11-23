import Foundation

/// One change to a table's fields, indexes or foreign keys, as Structure and
/// Foreign Keys ask for it, whatever the engine. `plan(_:)` turns it into what
/// runs: MySQL's ALTER TABLE, or SQLite's ALTER TABLE, CREATE/DROP INDEX or a
/// table rebuild (S-070). The controllers make one call per action and never
/// branch on the engine.
public enum TableChange: Sendable, Equatable {
    /// The field named `String` becomes the definition, moved to the position.
    case editField(String, FieldDefinition, FieldPosition)
    case addField(FieldDefinition, FieldPosition)
    /// A copy of the field named `String`, named "_copy", right after it.
    case duplicateField(String)
    case dropFields([String])
    case addIndex(IndexDefinition)
    case dropIndexes([String])
    case addForeignKey(ForeignKeyDefinition)
    /// Foreign keys by name, as `TableShape.foreignKeys` lists them.
    case dropForeignKeys([String])
}

/// What a plan needs to know about the table it changes.
public struct TableShape: Sendable {
    public var table: String
    public var database: String
    public var engine: Engine
    /// The fields in table order.
    public var fields: [FieldDefinition]
    /// The foreign keys' names in the order the server lists them (SQLite's are its ids).
    public var foreignKeys: [String]
    /// A SQLite table's CREATE TABLE, read into its parts; nil on MySQL.
    public var sqlite: SQLiteTable?

    public init(table: String, database: String, engine: Engine, fields: [FieldDefinition] = [],
                foreignKeys: [String] = [], sqlite: SQLiteTable? = nil) {
        self.table = table
        self.database = database
        self.engine = engine
        self.fields = fields
        self.foreignKeys = foreignKeys
        self.sqlite = sqlite
    }
}

/// What a change runs.
public enum TableChangePlan: Sendable, Equatable {
    /// Statements run one after another: MySQL's ALTER TABLE, SQLite's index SQL.
    case statements([String])
    /// ALTER TABLE in a transaction, with a rebuild when SQLite can't change the table in place.
    case sqlite(SQLiteChangePlan)

    /// Copying every row: big tables ask first.
    public var needsRebuild: Bool {
        if case .sqlite(let plan) = self { plan.needsRebuild } else { false }
    }

    /// Nothing to run: the change leaves the table as it is.
    public var isEmpty: Bool {
        switch self {
        case .statements(let statements): statements.isEmpty
        case .sqlite(let plan): plan.statements.isEmpty && !plan.needsRebuild
        }
    }

    /// What a sheet shows under its fields.
    public var summary: String {
        switch self {
        case .statements(let statements): statements.joined(separator: ";\n")
        case .sqlite(let plan): plan.summary
        }
    }
}

extension TableChange {
    public func plan(_ shape: TableShape) throws -> TableChangePlan {
        switch shape.engine {
        case .mysql: .statements(mysqlStatements(shape))
        case .sqlite: try sqlitePlan(shape)
        }
    }

    private func mysqlStatements(_ shape: TableShape) -> [String] {
        let (table, database) = (shape.table, shape.database)
        switch self {
        case .editField(let name, let field, let position):
            return [FieldChange.changeSQL(name, to: field, in: table, database: database, position: position)]
        case .addField(let field, let position):
            return [FieldChange.addSQL(field, to: table, in: database, position: position)]
        case .duplicateField(let name):
            guard let field = shape.fields.first(where: { $0.name == name }) else { return [] }
            let copy = FieldChange.duplicate(field, existing: shape.fields.map(\.name))
            return [FieldChange.addSQL(copy, to: table, in: database, position: .after(name))]
        case .dropFields(let names):
            return [FieldChange.dropSQL(names, from: table, in: database)]
        case .addIndex(let index):
            return [IndexChange.addSQL(index, to: table, in: database)]
        case .dropIndexes(let names):
            return [IndexChange.dropSQL(names, from: table, in: database)]
        case .addForeignKey(let key):
            return [ForeignKeyChange.addSQL(key, to: table, in: database)]
        case .dropForeignKeys(let names):
            return [ForeignKeyChange.dropSQL(names, from: table, in: database)]
        }
    }

    private func sqlitePlan(_ shape: TableShape) throws -> TableChangePlan {
        let change: SQLiteTableChange
        switch self {
        case .addIndex(let index):
            return .statements([IndexChange.sqliteAddSQL(index, to: shape.table)])
        case .dropIndexes(let names):
            return .statements(IndexChange.sqliteDropSQL(names))
        case .editField(let name, let field, let position):
            change = .edit(name, field, position)
        case .addField(let field, let position):
            change = .add(field, position)
        case .duplicateField(let name):
            guard let field = shape.fields.first(where: { $0.name == name }) else { return .statements([]) }
            // The copy starts empty, so a NOT NULL field with no default would refuse the table's rows.
            var copy = FieldChange.duplicate(field, existing: shape.fields.map(\.name))
            if !copy.isNullable, copy.defaultValue == .none { copy.isNullable = true; copy.defaultValue = .null }
            change = .add(copy, .after(name))
        case .dropFields(let names):
            change = .drop(names)
        case .addForeignKey(let key):
            change = .addForeignKey(key)
        case .dropForeignKeys(let names):
            // PRAGMA foreign_key_list's id is the key's place in the list.
            change = .dropForeignKeys(names.compactMap { shape.foreignKeys.firstIndex(of: $0) })
        }
        guard let create = shape.sqlite else {
            throw DatabaseError(message: "Quarry can’t read the CREATE TABLE of “\(shape.table)”.")
        }
        return .sqlite(try change.plan(table: shape.table, create: create, fields: shape.fields))
    }
}

extension DatabaseClient {
    /// The table as a change plans against it now; on SQLite with its CREATE TABLE read from the file.
    public func tableShape(_ table: String, in database: String, fields: [FieldDefinition] = [],
                           foreignKeys: [String] = []) async throws -> TableShape {
        let engine = dialect.engine
        let create = engine == .sqlite ? try await sqliteTable(table) : nil
        return TableShape(table: table, database: database, engine: engine, fields: fields,
                          foreignKeys: foreignKeys, sqlite: create)
    }

    /// Runs a table change's plan: its statements in order, or SQLite's transaction and rebuild.
    public func apply(_ plan: TableChangePlan) async throws {
        switch plan {
        case .statements(let statements):
            for sql in statements { _ = try await run(sql) }
        case .sqlite(let plan):
            try await applySQLite(plan)
        }
    }
}
