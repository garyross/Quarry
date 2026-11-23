import Foundation
import Testing
@testable import QuarryKit

/// S-072: Database Information on a SQLite file: the health rules on fixed
/// inputs, Integrity Check's messages by table, and the checks on a real file.
@Suite struct SQLiteMaintenanceTests {
    private func info(tables: [String] = ["customers", "orders"], pages: Int = 100, free: Int = 0) -> SQLiteFileInfo {
        SQLiteFileInfo(fileName: "demo.sqlite", fileBytes: pages * 4096, pageSize: 4096, pageCount: pages, freePages: free,
                       journalMode: "wal", encoding: "UTF-8", foreignKeys: true, version: "3.51.0", tables: tables)
    }

    private func input(_ info: SQLiteFileInfo, keys: Set<String> = ["customers", "orders"],
                       foreignKeys: [SQLiteForeignKey] = [], indexes: [String: [[String]]] = [:],
                       problems: [TableCheck] = []) -> SQLiteHealthInput {
        SQLiteHealthInput(info: info, tablesWithPrimaryKey: keys, foreignKeys: foreignKeys, indexes: indexes, keyProblems: problems)
    }

    // MARK: Health rules

    @Test func aHealthyFileHasOneOKFinding() {
        let key = SQLiteForeignKey(table: "orders", columns: ["customer_id"], parent: "customers", parentColumns: ["id"])
        let findings = SQLiteHealthCheck.run(input(info(), foreignKeys: [key], indexes: ["orders": [["id"], ["customer_id"]]]))
        #expect(findings.map(\.id) == ["ok"])
        #expect(findings[0].title == "No problems found")
    }

    @Test func freePagesOverAQuarterAreFlagged() {
        #expect(SQLiteHealthCheck.run(input(info(pages: 100, free: 25))).map(\.id) == ["ok"])
        let findings = SQLiteHealthCheck.run(input(info(pages: 100, free: 40)))
        #expect(findings.map(\.id) == ["free-pages"])
        #expect(findings[0].title == "40% of the file is free pages")
    }

    @Test func aReferencedTableWithNoPrimaryKeyIsFlagged() {
        let key = SQLiteForeignKey(table: "orders", columns: ["customer_id"], parent: "customers")
        let findings = SQLiteHealthCheck.run(input(info(), keys: ["orders"], foreignKeys: [key],
                                                   indexes: ["orders": [["customer_id"]]]))
        #expect(findings.map(\.id) == ["referenced-no-key"])
        #expect(findings[0].tables == ["customers"])
        // A foreign key that names the parent's columns refers to a unique column, not the primary key.
        let named = SQLiteForeignKey(table: "orders", columns: ["customer_id"], parent: "customers", parentColumns: ["email"])
        #expect(SQLiteHealthCheck.run(input(info(), keys: ["orders"], foreignKeys: [named],
                                            indexes: ["orders": [["customer_id"]]])).map(\.id) == ["ok"])
    }

    @Test func aForeignKeyWithNoIndexIsFlaggedWithItsCreateIndex() {
        let key = SQLiteForeignKey(table: "order_items", columns: ["product_id"], parent: "products", parentColumns: ["id"])
        let findings = SQLiteHealthCheck.run(input(info(tables: ["order_items", "products"]), keys: ["order_items", "products"],
                                                   foreignKeys: [key], indexes: ["order_items": [["order_id", "product_id"]]]))
        #expect(findings.map(\.id) == ["foreign-key-index"])
        #expect(findings[0].sql == "CREATE INDEX `order_items_product_id_idx` ON `order_items` (`product_id`);")
    }

    @Test func anIndexCoversAKeyWhenItsFirstColumnsAreTheKeys() {
        let key = SQLiteForeignKey(table: "t", columns: ["a", "b"], parent: "p")
        #expect(SQLiteHealthCheck.isIndexed(key, indexes: [["B", "a", "c"]]))
        #expect(!SQLiteHealthCheck.isIndexed(key, indexes: [["a"], ["c", "a", "b"]]))
    }

    @Test func foreignKeyErrorsComeFirst() {
        let findings = SQLiteHealthCheck.run(input(info(pages: 10, free: 5), problems: [
            TableCheck(table: "orders", severity: .error, message: "1 row refers to missing rows in customers"),
            TableCheck(table: "customers", severity: .ok, message: "OK"),
        ]))
        #expect(findings.map(\.id) == ["foreign-key-errors", "free-pages"])
        #expect(findings[0].tables == ["orders"])
    }

    // MARK: Reading the checks

    @Test func integrityMessagesGoUnderTheTableTheyName() {
        let results = SQLiteIntegrity.results(
            messages: ["row 3 missing from index orders_customer", "wrong # of entries in index orders_customer",
                       "NULL value in customers.name", "Freelist: size is 3 but should be 2"],
            fileName: "demo.sqlite", tables: ["customers", "orders"], indexes: ["orders_customer": "orders"])
        #expect(results.map(\.table) == ["orders", "customers", "demo.sqlite"])
        #expect(results[0].message == "row 3 missing from index orders_customer (and 1 more)")
        #expect(SQLiteIntegrity.results(messages: ["ok"], fileName: "f", tables: [], indexes: [:]).isEmpty)
    }

    @Test func foreignKeyCheckRowsBecomeOneLinePerParent() {
        let problems = [SQLiteKeyProblem(table: "orders", rowid: 7, parent: "customers"),
                        SQLiteKeyProblem(table: "orders", rowid: 9, parent: "customers")]
        #expect(SQLiteIntegrity.keyCheck(table: "orders", problems: problems).message
            == "2 rows refer to missing rows in customers (rowid 7, 9)")
        #expect(SQLiteIntegrity.keyCheck(table: "customers", problems: problems).severity == .ok)
    }

    @Test func theVacuumWords() {
        let file = info(pages: 100, free: 50)
        #expect(file.vacuumMessage.hasPrefix("SQLite rewrites the file to give back "))
        #expect(file.vacuumMessage.hasSuffix("Other apps can’t write to it until it’s done."))
        #expect(SQLiteFileInfo.vacuumResult("demo.sqlite", before: 48_000_000, after: 36_000_000)
            == "demo.sqlite went from \(ByteCount.format(48_000_000)) to \(ByteCount.format(36_000_000)).")
        #expect(TableOperation.check.works(on: .sqlite) && TableOperation.analyze.works(on: .sqlite)
            && !TableOperation.repair.works(on: .sqlite) && !TableOperation.checksum.works(on: .sqlite))
    }

    // MARK: A real file

    @Test func theChecksOnARealFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "quarry-s072-\(UUID().uuidString).sqlite")
        try SQLiteFile.create(url)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = try await DatabaseClient.connect(ConnectionDetails(transport: .sqlite, file: url.path))
        for sql in ["CREATE TABLE p (id INTEGER PRIMARY KEY)", "CREATE TABLE c (id INTEGER PRIMARY KEY, pid REFERENCES p(id))",
                    "CREATE TABLE loose (a)", "CREATE TABLE refers (x REFERENCES loose)", "CREATE TABLE junk (b)",
                    "INSERT INTO junk SELECT randomblob(2000) FROM (WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 300) SELECT i FROM n)",
                    "DELETE FROM junk", "PRAGMA foreign_keys = OFF", "INSERT INTO p VALUES (1)", "INSERT INTO c VALUES (1, 1), (2, 5)"] {
            _ = try await client.run(sql)
        }
        let file = try await client.sqliteFileInfo()
        #expect(file.fileName == url.lastPathComponent && file.tables.count == 5 && file.pageSize > 0 && file.freePages > 0)
        #expect(file.encoding == "UTF-8" && !file.foreignKeys && !file.isReadOnly)
        #expect(try await client.sqliteIntegrityCheck(file).isEmpty)

        let keys = try await client.sqliteForeignKeyCheck(file.tables)
        #expect(keys.first { $0.table == "c" }?.message == "1 row refers to missing rows in p (rowid 2)")
        #expect(keys.first { $0.table == "refers" }?.message.contains("foreign key mismatch") == true)
        #expect(keys.first { $0.table == "p" }?.severity == .ok)

        let ids = SQLiteHealthCheck.run(try await client.sqliteHealthInput(file)).map(\.id)
        #expect(ids == ["foreign-key-errors", "referenced-no-key", "foreign-key-index", "free-pages"])

        let checked = try await client.run(.check, on: ["c"], in: "main")
        #expect(checked == [TableCheck(table: "c", severity: .ok, message: "OK")])
        #expect(try await client.run(.analyze, on: ["c"], in: "main").first?.message == "Statistics updated")
        try await client.sqliteOptimize()
        try await client.sqliteVacuum()
        let after = try await client.sqliteFileInfo()
        #expect(after.freePages == 0 && after.fileBytes < file.fileBytes)
        await client.close()
    }
}
