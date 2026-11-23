import Foundation
import Testing
@testable import QuarryKit

/// S-070: changing a SQLite table's structure: reading CREATE TABLE, the plan
/// for each kind of change, and a rebuild that keeps rows, indexes and triggers.
@Suite struct SQLiteStructureTests {
    private let orders = #"""
        CREATE TABLE orders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          customer_id INTEGER NOT NULL REFERENCES customers(id) ON DELETE SET NULL NOT DEFERRABLE,
          -- a comment
          status TEXT NOT NULL DEFAULT 'new' COLLATE NOCASE,
          total REAL DEFAULT -1.5 CHECK (total >= -10),
          made TEXT DEFAULT (datetime('now')),
          "odd ""name""" VARCHAR(20, 2),
          twice AS (total * 2),
          FOREIGN KEY (status) REFERENCES statuses (name),
          UNIQUE (customer_id, made)
        ) STRICT, WITHOUT ROWID
        """#

    @Test func readsColumnsConstraintsAndOptions() throws {
        let table = try #require(SQLiteTable(sql: orders))
        #expect(table.columns.map(\.name) == ["id", "customer_id", "status", "total", "made", "odd \"name\"", "twice"])
        #expect(table.columns[0].isPrimaryKey && table.columns[0].isAutoIncrement && table.columns[0].type == "INTEGER")
        #expect(table.columns[1].constraints.map(\.text)
            == ["NOT NULL", "REFERENCES customers(id) ON DELETE SET NULL NOT DEFERRABLE"])
        #expect(table.columns[2].defaultSQL == "'new'" && table.columns[2].collation == "NOCASE" && table.columns[2].isNotNull)
        #expect(table.columns[3].defaultSQL == "-1.5" && table.columns[3].constraints.last?.kind == "CHECK")
        #expect(table.columns[4].defaultSQL == "(datetime('now'))")
        #expect(table.columns[5].type == "VARCHAR(20, 2)")
        #expect(table.columns[6].isGenerated)
        #expect(table.constraints.map(\.kind) == ["FOREIGN", "UNIQUE"])
        #expect(table.isStrict && table.isWithoutRowID && table.optionNames == ["STRICT", "WITHOUT ROWID"])
        // Written back, it reads the same.
        #expect(SQLiteTable(sql: table.createSQL(named: "orders")) == table)
    }

    @Test func foreignKeysAreNumberedFromTheLast() throws {
        let table = try #require(SQLiteTable(sql: orders))
        #expect(table.foreignKeyPlaces == [.column(1, constraint: 1), .table(0)])
        // id 0 is the last declared: the FOREIGN KEY clause.
        let without = try table.removingForeignKeys(ids: [0])
        #expect(without.constraints.map(\.kind) == ["UNIQUE"] && without.columns[1].hasReferences)
        let neither = try table.removingForeignKeys(ids: [0, 1])
        #expect(!neither.columns[1].hasReferences && neither.columns[1].isNotNull)
        #expect(throws: DatabaseError.self) { try table.removingForeignKeys(ids: [5]) }
    }

    private func fields(_ table: SQLiteTable) -> [FieldDefinition] {
        table.columns.map { column in
            let info = FieldInfo(name: column.name, fullType: column.type, isNullable: !column.isNotNull && !column.isPrimaryKey,
                                 key: column.isPrimaryKey ? "PRI" : "",
                                 defaultValue: column.defaultSQL.map { SQLiteDialect.defaultValue($0) ?? $0 },
                                 extra: column.isAutoIncrement ? "autoincrement" : "", collation: nil, comment: "")
            return FieldDefinition(sqlite: info, column: column)
        }
    }

    @Test func aRenameIsAnAlterTable() throws {
        let table = try #require(SQLiteTable(sql: orders))
        var field = fields(table)[2]
        #expect(field.defaultValue == .value("new") && field.collation == "NOCASE")
        field.name = "state"
        let plan = try SQLiteTableChange.edit("status", field, .unchanged).plan(table: "orders", create: table, fields: fields(table))
        #expect(plan.statements == ["ALTER TABLE \"orders\" RENAME COLUMN \"status\" TO \"state\""] && !plan.needsRebuild)
    }

    @Test func aTypeOrDefaultChangeRebuildsAndKeepsTheRest() throws {
        let table = try #require(SQLiteTable(sql: orders))
        var field = fields(table)[3]
        field = FieldDefinition(name: "amount", type: "numeric", isNullable: false, defaultValue: .value("0"))
        let plan = try SQLiteTableChange.edit("total", field, .unchanged).plan(table: "orders", create: table, fields: fields(table))
        #expect(plan.statements == ["ALTER TABLE \"orders\" RENAME COLUMN \"total\" TO \"amount\""])
        let column = try #require(plan.rebuild?.columns[3])
        #expect(column.sql == "\"amount\" NUMERIC DEFAULT 0 CHECK (total >= -10) NOT NULL")
        // The generated field isn't copied; the others are, by their new names.
        #expect(plan.copied == ["id", "customer_id", "status", "amount", "made", "odd \"name\""])
        let script = plan.script
        #expect(script[1].hasPrefix("CREATE TABLE \"quarry_new_orders\" ("))
        #expect(script[2] == "INSERT INTO \"quarry_new_orders\" (\"id\", \"customer_id\", \"status\", \"amount\", \"made\", \"odd \"\"name\"\"\") "
            + "SELECT \"id\", \"customer_id\", \"status\", \"amount\", \"made\", \"odd \"\"name\"\"\" FROM \"orders\"")
        #expect(script[3].hasPrefix("UPDATE sqlite_sequence SET seq = max(seq,"))
        #expect(Array(script.suffix(4)) == ["DROP TABLE \"orders\"", "PRAGMA legacy_alter_table = ON",
                                             "ALTER TABLE \"quarry_new_orders\" RENAME TO \"orders\"", "PRAGMA legacy_alter_table = OFF"])
        #expect(plan.summary.hasPrefix("Rebuilds the table:\nCREATE TABLE \"orders\""))
    }

    @Test func movingAFieldRebuildsInTheNewOrder() throws {
        let table = try #require(SQLiteTable(sql: orders))
        let all = fields(table)
        let plan = try SQLiteTableChange.edit("made", all[4], .first).plan(table: "orders", create: table, fields: all)
        #expect(plan.statements.isEmpty && plan.rebuild?.columns.map(\.name).first == "made")
        #expect(plan.rebuild?.columns.first?.sql == "\"made\" TEXT DEFAULT (datetime('now'))")
        // No change at all is no plan.
        let none = try SQLiteTableChange.edit("made", all[4], .unchanged).plan(table: "orders", create: table, fields: all)
        #expect(none.statements.isEmpty && !none.needsRebuild)
    }

    @Test func addingAtTheEndIsAnAlterTableUnlessSQLiteRefusesIt() throws {
        let table = try #require(SQLiteTable(sql: "CREATE TABLE t (a INTEGER PRIMARY KEY, b TEXT)"))
        let all = fields(table)
        let plain = FieldDefinition(name: "c", type: "text", defaultValue: .value("x"))
        let simple = try SQLiteTableChange.add(plain, .after("b")).plan(table: "t", create: table, fields: all)
        #expect(simple.statements == ["ALTER TABLE \"t\" ADD COLUMN \"c\" TEXT DEFAULT 'x'"])
        let stamped = FieldDefinition(name: "c", type: "text", defaultValue: .expression("CURRENT_TIMESTAMP"))
        let rebuilt = try SQLiteTableChange.add(stamped, .after("b")).plan(table: "t", create: table, fields: all)
        #expect(rebuilt.needsRebuild && rebuilt.copied == ["a", "b"] && rebuilt.rebuild?.columns.count == 3)
        let first = try SQLiteTableChange.add(plain, .first).plan(table: "t", create: table, fields: all)
        #expect(first.rebuild?.columns.map(\.name) == ["c", "a", "b"])
        let required = FieldDefinition(name: "c", type: "integer", isNullable: false)
        #expect(try SQLiteTableChange.add(required, .unchanged).plan(table: "t", create: table, fields: all).needsRebuild)
    }

    @Test func foreignKeysAddAndDropByRebuild() throws {
        let table = try #require(SQLiteTable(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, order_id INTEGER)"))
        let key = ForeignKeyDefinition(field: "order_id", referencedTable: "orders", referencedField: "id",
                                       onUpdate: .noAction, onDelete: .cascade)
        let plan = try SQLiteTableChange.addForeignKey(key).plan(table: "items", create: table, fields: fields(table))
        #expect(plan.rebuild?.constraints.map(\.text) == ["FOREIGN KEY (\"order_id\") REFERENCES \"orders\" (\"id\") ON DELETE CASCADE"])
        let dropped = try SQLiteTableChange.dropForeignKeys([0]).plan(table: "items", create: plan.rebuild!, fields: fields(table))
        #expect(dropped.rebuild?.constraints.isEmpty == true)
        #expect(try SQLiteTableChange.drop(["order_id"]).plan(table: "items", create: table, fields: fields(table)).statements
            == ["ALTER TABLE \"items\" DROP COLUMN \"order_id\""])
    }

    @Test func defaultsAsSQLiteWritesThem() {
        #expect(SQLiteTableChange.defaultSQL(.value("12")) == "12")
        #expect(SQLiteTableChange.defaultSQL(.value("it's")) == "'it''s'")
        #expect(SQLiteTableChange.defaultSQL(.expression("datetime('now')")) == "(datetime('now'))")
        #expect(SQLiteTableChange.defaultSQL(.expression("CURRENT_TIMESTAMP")) == "CURRENT_TIMESTAMP")
        #expect(SQLiteTableChange.defaultSQL(.null) == "NULL")
        #expect(SQLiteTableChange.typedDefault("(1 + 2)") == .expression("(1 + 2)"))
        #expect(SQLiteTableChange.typedDefault("hello") == .value("hello"))
        #expect(SQLiteTableChange.types(strict: true).contains("ANY"))
    }

    @Test func autoIncrementMovesThePrimaryKeyIntoTheColumn() throws {
        let table = try #require(SQLiteTable(sql: "CREATE TABLE t (id INTEGER NOT NULL, b TEXT, PRIMARY KEY (id))"))
        var field = fields(table)[0]
        field.extra = .autoIncrement
        let plan = try SQLiteTableChange.edit("id", field, .unchanged).plan(table: "t", create: table, fields: fields(table))
        #expect(plan.rebuild?.columns[0].sql == "\"id\" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL")
        #expect(plan.rebuild?.constraints.isEmpty == true)
    }

    @Test func aCopiedIndexNamesTheCopy() {
        #expect(DatabaseClient.copiedIndexSQL("CREATE INDEX orders_status ON orders(status)", index: "orders_status",
                                              from: "orders", to: "orders_copy")
            == "CREATE INDEX \"orders_copy_status\" ON \"orders_copy\"(status)")
        #expect(DatabaseClient.copiedIndexSQL("CREATE UNIQUE INDEX \"by sku\" ON \"p\" (sku)", index: "by sku", from: "p", to: "p2")
            == "CREATE UNIQUE INDEX \"by sku_p2\" ON \"p2\" (sku)")
    }

    // MARK: On a file

    private func file(_ sql: String) async throws -> DatabaseClient {
        let url = FileManager.default.temporaryDirectory.appending(path: "quarry-s070-\(UUID().uuidString).sqlite")
        try SQLiteFile.create(url)
        let client = try await DatabaseClient.connect(ConnectionDetails(transport: .sqlite, file: url.path))
        for statement in sql.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !statement.isEmpty {
            _ = try await client.run(statement)
        }
        return client
    }

    private static let schema = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE customers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);
        CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id) ON DELETE CASCADE, note TEXT);
        CREATE INDEX customers_name ON customers(name);
        CREATE VIEW names AS SELECT name FROM customers;
        INSERT INTO customers (name) VALUES ('Ada'), ('Grace'), ('Alan');
        DELETE FROM customers WHERE id = 3;
        INSERT INTO orders (customer_id) VALUES (1), (2)
        """

    private func fieldsOnFile(_ client: DatabaseClient, _ table: String) async throws -> [FieldDefinition] {
        let create = try await client.sqliteTable(table)
        return try await client.fields(of: table, in: "main").map { info in
            FieldDefinition(sqlite: info, column: create.column(named: info.name).map { create.columns[$0] })
        }
    }

    @Test func aRebuildKeepsRowsIndexesViewsAndTheSequence() async throws {
        let client = try await file(Self.schema)
        _ = try await client.run("CREATE TRIGGER t AFTER INSERT ON customers BEGIN SELECT 1; END")
        let create = try await client.sqliteTable("customers")
        let all = try await fieldsOnFile(client, "customers")
        var name = all[1]
        name.isNullable = false
        name.defaultValue = .value("")
        name.collation = "NOCASE"
        let plan = try SQLiteTableChange.edit("name", name, .unchanged).plan(table: "customers", create: create, fields: all)
        try await client.applySQLite(plan)
        let after = try await client.sqliteTable("customers")
        #expect(after.columns[1].sql == "\"name\" TEXT NOT NULL DEFAULT '' COLLATE NOCASE")
        #expect(try await client.run("SELECT count(*) FROM customers").rows.first?.first?.plainText == "2")
        // Cascades didn't fire when the old table went.
        #expect(try await client.run("SELECT count(*) FROM orders").rows.first?.first?.plainText == "2")
        let objects = try await client.run("SELECT name FROM sqlite_schema WHERE tbl_name IN ('customers', 'names') ORDER BY name")
            .rows.compactMap { $0.first?.plainText }
        #expect(objects == ["customers", "customers_name", "names", "t"])
        #expect(try await client.run("SELECT seq FROM sqlite_sequence WHERE name = 'customers'").rows.first?.first?.plainText == "3")
        #expect(try await client.run("PRAGMA foreign_keys").rows.first?.first?.plainText == "1")
        await client.close()
    }

    @Test func aFailedRebuildLeavesTheTableAsItWas() async throws {
        let client = try await file(Self.schema + "; INSERT INTO customers (name) VALUES (NULL)")
        let before = try await client.sqliteTable("customers")
        let all = try await fieldsOnFile(client, "customers")
        var name = all[1]
        name.isNullable = false
        let plan = try SQLiteTableChange.edit("name", name, .unchanged).plan(table: "customers", create: before, fields: all)
        await #expect(throws: DatabaseError.self) { try await client.applySQLite(plan) }
        do { try await client.applySQLite(plan) } catch let error as DatabaseError {
            #expect(error.message.contains("customers.name") && !error.message.contains("quarry_new"))
        }
        #expect(try await client.sqliteTable("customers") == before)
        #expect(try await client.run("SELECT count(*) FROM customers").rows.first?.first?.plainText == "3")
        await client.close()
    }

    @Test func aForeignKeyWithMissingParentsRollsBack() async throws {
        let client = try await file(Self.schema + "; CREATE TABLE notes (id INTEGER PRIMARY KEY, customer_id INTEGER); "
            + "INSERT INTO notes (customer_id) VALUES (1), (99)")
        let create = try await client.sqliteTable("notes")
        let key = ForeignKeyDefinition(field: "customer_id", referencedTable: "customers", referencedField: "id",
                                       onUpdate: .noAction, onDelete: .noAction)
        let plan = try SQLiteTableChange.addForeignKey(key).plan(table: "notes", create: create,
                                                                  fields: try await fieldsOnFile(client, "notes"))
        do {
            try await client.applySQLite(plan)
            Issue.record("the rebuild should fail")
        } catch let error as DatabaseError {
            #expect(error.message == "Rows in “notes” would point at rows “customers” doesn’t have.")
        }
        #expect(try await client.sqliteTable("notes") == create)
        _ = try await client.run("DELETE FROM notes WHERE customer_id = 99")
        try await client.applySQLite(plan)
        #expect(try await client.foreignKeys(of: "notes", in: "main").count == 1)
        await client.close()
    }
}
