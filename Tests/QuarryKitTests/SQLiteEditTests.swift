import Foundation
import Testing
@testable import QuarryKit

/// S-069: editing rows in a SQLite file: RowEdit's SQLite statements, the
/// rowid for tables with no primary key, defaults, and stored types.
@Suite struct SQLiteEditTests {
    private let keyed = [ResultColumn(name: "id", isPrimaryKey: true), ResultColumn(name: "name")]

    @Test func statementsHaveNoLimitOnSQLite() {
        #expect(RowEdit.updateSQL(database: "main", table: "t", columns: keyed, row: [.text("7"), .text("a")],
                                  changes: [1: .text("b")], engine: .sqlite)
            == "UPDATE `main`.`t` SET `name` = 'b' WHERE `id` = '7'")
        #expect(RowEdit.deleteSQL(database: "main", table: "t", columns: keyed, row: [.text("7"), .null], engine: .sqlite)
            == "DELETE FROM `main`.`t` WHERE `id` = '7'")
        // MySQL keeps its LIMIT 1.
        #expect(RowEdit.deleteSQL(database: "d", table: "t", columns: keyed, row: [.text("7"), .null], engine: .mysql).hasSuffix(" LIMIT 1"))
    }

    @Test func aRowWithNoKeyIsFoundByRowID() {
        let columns = [ResultColumn(name: "body"), ResultColumn(name: "rowid", isPrimaryKey: true)]
        #expect(RowEdit.updateSQL(database: "main", table: "notes", columns: columns, row: [.text("x"), .text("3")],
                                  changes: [0: .text("y")], engine: .sqlite)
            == "UPDATE `main`.`notes` SET `body` = 'y' WHERE `rowid` = '3'")
        #expect(SQLiteDialect().pageSQL(table: "notes", database: "main", where: nil, orderBy: nil, ascending: true,
                                        offset: 0, limit: 10, rowID: "rowid")
            == "SELECT `rowid`, * FROM `main`.`notes` LIMIT 10 OFFSET 0")
        #expect(SQLiteDialect.rowIDName(avoiding: ["body"]) == "rowid")
        #expect(SQLiteDialect.rowIDName(avoiding: ["ROWID", "x"]) == "_rowid_")
        #expect(SQLiteDialect.rowIDName(avoiding: ["rowid", "_rowid_", "oid"]) == nil)
    }

    @Test func insertWithNoValuesUsesDefaultValues() {
        #expect(RowEdit.insertSQL(database: "main", table: "notes", values: [], engine: .sqlite)
            == "INSERT INTO `main`.`notes` DEFAULT VALUES")
        #expect(RowEdit.insertSQL(database: "main", table: "notes", values: [("body", .text("hi"))], engine: .sqlite)
            == "INSERT INTO `main`.`notes` (`body`) VALUES ('hi')")
    }

    @Test func defaultsReadAsMySQLGivesThem() {
        #expect(SQLiteDialect.defaultValue("'US'") == "US")
        #expect(SQLiteDialect.defaultValue("'it''s'") == "it's")
        #expect(SQLiteDialect.defaultValue("0") == "0")
        #expect(SQLiteDialect.defaultValue("CURRENT_TIMESTAMP") == "CURRENT_TIMESTAMP")
        #expect(SQLiteDialect.defaultValue("NULL") == "NULL")
        #expect(SQLiteDialect.defaultValue("'a' || 'b'") == "'a' || 'b'")
        #expect(SQLiteDialect.defaultValue(nil) == nil)
    }

    @Test func newRowsLeaveTheRowIDToSQLite() {
        func field(_ extra: String, default value: String? = nil) -> FieldInfo {
            FieldInfo(name: "id", fullType: "INTEGER", isNullable: false, key: "PRI", defaultValue: value, extra: extra,
                      collation: nil, comment: "")
        }
        #expect(NewRow.isAutoIncrement(field("rowid")) && NewRow.isAutoIncrement(field("autoincrement")))
        #expect(NewRow.initialValue(field("rowid")) == .null)
        #expect(!NewRow.copiesValue(field("autoincrement")))
    }

    @Test func storedTypeNotes() {
        #expect(SQLiteAffinity("INTEGER").storedNote(.text("draft")) == "Stored as TEXT")
        #expect(SQLiteAffinity("INTEGER").storedNote(.text("42")) == nil)
        #expect(SQLiteAffinity("REAL").storedNote(.text("2.5")) == nil)
        #expect(SQLiteAffinity("TEXT").storedNote(.binary(Data([1]))) == "Stored as BLOB")
        #expect(SQLiteAffinity("BLOB").storedNote(.text("x")) == nil)
        #expect(SQLiteAffinity("TEXT").storedNote(.null) == nil)
    }

    @Test func editsOnTheFile() async throws {
        let client = try await SQLiteDialectTests.open(try SQLiteDialectTests.fixture())
        // The driver marks primary-key columns, so a page's rows are found by their key.
        let page = try await client.page(of: "order_items", in: "main", orderBy: nil, ascending: true, offset: 0, limit: 1)
        #expect(page.columns.map(\.isPrimaryKey) == [true, true, false, false])
        let update = RowEdit.updateSQL(database: "main", table: "order_items", columns: page.columns, row: page.rows[0],
                                       changes: [2: .text("5")], engine: .sqlite)
        #expect(try await client.run(update).affectedRows == 1)

        // A WITHOUT ROWID table has its primary key.
        let settings = try await client.page(of: "settings", in: "main", orderBy: "key", ascending: true, offset: 0, limit: 5)
        #expect(settings.columns.first?.isPrimaryKey == true)
        #expect(settings.rows[0][2] == .text("draft"))

        // A table with no key: the rowid comes first.
        let notes = try await client.page(of: "notes", in: "main", orderBy: nil, ascending: true, offset: 0, limit: 5, rowID: "rowid")
        #expect(notes.columns.count == 2 && notes.rows.first?.first == .text("1"))
        let delete = RowEdit.deleteSQL(database: "main", table: "notes",
                                       columns: [ResultColumn(name: "body"), ResultColumn(name: "rowid", isPrimaryKey: true)],
                                       row: [notes.rows[0][1], notes.rows[0][0]], engine: .sqlite)
        #expect(try await client.run(delete).affectedRows == 1)
        #expect(try await client.insert(RowEdit.insertSQL(database: "main", table: "notes", values: [], engine: .sqlite)) == 1)

        // Foreign keys are enforced on Quarry's connection.
        await #expect(throws: DatabaseError.self) {
            try await client.run("INSERT INTO orders (customer_id, placed_at) VALUES (999, '2026-01-01')")
        }
        // REFERENCES customers (no column) names its primary key.
        _ = try await client.run("CREATE TABLE refunds (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers)")
        #expect(try await client.foreignKeys(of: "refunds", in: "main").first?.referencedColumns == "id")
        await client.close()
    }
}
