import Foundation
import Testing
@testable import QuarryKit

/// S-068: the SQLite dialect's schema reads and values, on a copy of
/// tools/fixture-sqlite.sql made in a temporary folder.
@Suite struct SQLiteDialectTests {
    /// A fresh fixture file, made with the system's sqlite3.
    static func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "quarry-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "quarry_demo.sqlite")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "tools/fixture-sqlite.sql")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path]
        process.standardInput = try FileHandle(forReadingFrom: script)
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return url
    }

    static func open(_ url: URL, readOnly: Bool = false) async throws -> DatabaseClient {
        try await DatabaseClient.connect(ConnectionDetails(transport: .sqlite, file: url.path, readOnly: readOnly))
    }

    @Test func detailsForAFile() {
        let details = ConnectionDetails(transport: .sqlite, file: "~/Data/demo.sqlite", readOnly: true)
        #expect(details.engine == .sqlite)
        #expect(details.displayName == "demo.sqlite")
        #expect(details.summary == "~/Data/demo.sqlite · Read Only")
        #expect(details.problem == nil)
        #expect(ConnectionDetails(transport: .sqlite).problem == "Choose a SQLite file.")
        #expect(ConnectionDetails.Transport.sqlite.title == "SQLite File")
    }

    @Test func pageAndCountSQL() {
        let dialect = SQLiteDialect()
        #expect(dialect.pageSQL(table: "orders", database: "main", where: "`status` = 'new'", orderBy: "placed_at",
                                ascending: false, offset: 200, limit: 100)
            == "SELECT * FROM `main`.`orders` WHERE `status` = 'new' ORDER BY `placed_at` DESC LIMIT 100 OFFSET 200")
        #expect(dialect.countSQL(table: "orders", database: "main", where: nil) == "SELECT COUNT(*) FROM `main`.`orders`")
        #expect(dialect.useSQL("main") == nil)
        #expect(dialect.killSQL(1, connection: false) == nil)
        #expect(dialect.processListSQL(full: true) == nil)
    }

    /// The agents' create_statement and Show Create Statement read the same sqlite_schema text.
    @Test func createStatementOfATriggerAndOfNothing() async throws {
        let client = try await Self.open(try Self.fixture())
        let trigger = try await client.createStatement(kind: "trigger", of: "products_stock_check", in: "main")
        #expect(trigger?.hasPrefix("CREATE TRIGGER products_stock_check BEFORE UPDATE OF stock ON products") == true)
        #expect(try await client.createStatement(kind: "table", of: "no_such_table", in: "main") == nil)
        #expect(try await client.createStatement(of: DBObject(name: "notes", kind: .table), in: "main") == "CREATE TABLE notes (body TEXT);")
        await client.close()
    }

    @Test func schemaReads() async throws {
        let client = try await Self.open(try Self.fixture())
        #expect(try await client.databases() == ["main"])
        #expect(client.serverDescription.hasPrefix("SQLite 3."))
        let objects = try await client.objects(in: "main")
        #expect(objects.map(\.name) == ["customers", "events", "notes", "order_items", "orders", "products", "settings", "order_totals"])
        #expect(objects.last?.kind == .view)

        let fields = try await client.fields(of: "customers", in: "main")
        #expect(fields.map(\.name) == ["id", "name", "email", "country", "created_at"])
        #expect(fields[0].key == "PRI" && fields[0].extra == "autoincrement" && !fields[0].isNullable)
        #expect(!fields[1].isNullable && fields[2].isNullable)
        #expect(fields[3].defaultValue == "US" && fields[4].defaultValue == "CURRENT_TIMESTAMP")
        #expect(try await client.fields(of: "products", in: "main")[0].extra == "rowid")

        let indexes = try await client.indexes(of: "order_items", in: "main")
        #expect(indexes.rows.indices.map { indexes.string($0, "Key_name") } == ["PRIMARY", "PRIMARY"])
        #expect(indexes.rows.indices.map { indexes.string($0, "Column_name") } == ["order_id", "product_id"])
        let orderIndexes = try await client.indexes(of: "orders", in: "main")
        #expect(orderIndexes.rows.indices.map { orderIndexes.string($0, "Key_name") ?? "" }
            == ["PRIMARY", "orders_customer", "orders_status_placed", "orders_status_placed"])
        #expect(orderIndexes.string(1, "Non_unique") == "1")

        let keys = try await client.foreignKeys(of: "order_items", in: "main")
        #expect(keys.count == 2)
        #expect(Set(keys.map(\.referencedTable)) == ["orders", "products"])
        let cascade = try await client.foreignKeys(of: "orders", in: "main")
        #expect(cascade.first?.columns == "customer_id" && cascade.first?.onDelete == "CASCADE")

        let triggers = TriggerDefinition.list(from: try await client.triggers(of: "products", in: "main"))
        #expect(triggers.map(\.name) == ["products_stock_check"])
        #expect(triggers.first?.timing == .before && triggers.first?.event == .update)
        #expect(try await client.triggerNames(in: "main") == ["products_stock_check"])

        let create = try await client.createStatement(of: DBObject(name: "notes", kind: .table), in: "main")
        #expect(create == "CREATE TABLE notes (body TEXT);")
        #expect(try await client.rowCount(of: "customers", in: "main") == 6)
        let completions = try await client.completionTables(in: "main")
        #expect(completions.first { $0.name == "orders" }?.columns.count == 5)
        await client.close()
    }

    @Test func values() async throws {
        let client = try await Self.open(try Self.fixture())
        let page = try await client.page(of: "products", in: "main", orderBy: "id", ascending: true, offset: 0, limit: 2)
        #expect(page.columns.map(\.name) == ["id", "sku", "title", "price", "stock", "photo"])
        #expect(page.columns[0].isNumeric && page.columns[0].table == "products" && page.columns[5].isBinary)
        #expect(page.rows[0][0] == .text("1"))
        #expect(page.rows[0][3] == .text("129.0"))
        #expect(page.rows[1][3] == .text("79.5"))
        #expect(page.rows[0][5] == .binary(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])))
        #expect(page.rows[1][5] == .null)
        #expect(page.rows[0][2] == .text("Mechanical Keyboard"))

        // Columns come back even with no rows.
        let none = try await client.run("SELECT id, name FROM customers WHERE id < 0")
        #expect(none.columns.map(\.name) == ["id", "name"] && none.rows.isEmpty && none.returnsRows)

        let update = try await client.run("UPDATE products SET stock = stock + 1 WHERE id <= 2")
        #expect(update.affectedRows == 2)
        let id = try await client.insert("INSERT INTO notes (body) VALUES ('second')")
        #expect(id == 2)
        await #expect(throws: DatabaseError.self) { try await client.run("UPDATE products SET stock = -1 WHERE id = 1") }
        await client.close()
    }

    @Test func readOnlyRefusesWrites() async throws {
        let client = try await Self.open(try Self.fixture(), readOnly: true)
        do {
            _ = try await client.run("DELETE FROM notes")
            Issue.record("A read-only file took a write.")
        } catch let error as DatabaseError {
            #expect(error.message.contains("read only"))
        }
        await client.close()
    }

    @Test func filesThatArentThere() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "quarry-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let missing = folder.appending(path: "demo.sqlite")
        await #expect(throws: DatabaseError(message: "Can’t find “demo.sqlite”. It was moved or deleted.",
                                            code: SQLiteDriver.cantOpenCode,
                                            suggestion: "Locate the file, or remove the connection.")) {
            _ = try await Self.open(missing)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        let notes = folder.appending(path: "notes.db")
        try Data("just some text, not a database at all".utf8).write(to: notes)
        do {
            _ = try await Self.open(notes)
            Issue.record("A text file opened.")
        } catch let error as DatabaseError {
            #expect(error.message == "“notes.db” isn’t a SQLite database.")
        }
        #expect(!SQLiteDriver.isSQLiteFile(notes))

        let empty = folder.appending(path: "new.sqlite")
        try SQLiteDriver.create(empty)
        #expect(SQLiteDriver.isSQLiteFile(empty))
        let client = try await Self.open(empty)
        #expect(try await client.objects(in: "main").isEmpty)
        await client.close()
        #expect(throws: DatabaseError.self) { try SQLiteDriver.create(empty) }
    }

    @Test func aFileDeletedWhileOpenIsLost() async throws {
        let url = try Self.fixture()
        let client = try await Self.open(url)
        try FileManager.default.removeItem(at: url)
        await #expect(throws: DatabaseError.self) { try await client.run("SELECT 1") }
        #expect(await client.wasLost)
        await client.close()
    }

    @Test func busyWaitsThenSaysSo() async throws {
        let url = try Self.fixture()
        let holder = try await Self.open(url)
        _ = try await holder.run("BEGIN EXCLUSIVE")
        let started = ContinuousClock.now
        do {
            // Opening reads the schema, so the wait comes there.
            let other = try await Self.open(url)
            _ = try await other.run("SELECT COUNT(*) FROM customers")
            Issue.record("A locked file answered.")
        } catch let error as DatabaseError {
            #expect(error.message == "“quarry_demo.sqlite” is busy. Another app is writing to it.")
        }
        #expect(ContinuousClock.now - started >= .seconds(4))
        _ = try await holder.run("ROLLBACK")
        await holder.close()
    }

    @Test func cancelInterrupts() async throws {
        let client = try await Self.open(try Self.fixture())
        let long = Task {
            try await client.run("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) SELECT COUNT(*) FROM n")
        }
        try await Task.sleep(for: .milliseconds(200))
        try await client.cancelRunningQuery()
        do {
            _ = try await long.value
            Issue.record("The query finished.")
        } catch let error as DatabaseError {
            #expect(error.code == DatabaseClient.queryInterruptedCode)
        }
        #expect(try await client.run("SELECT 1").rows == [[.text("1")]])
        await client.close()
    }

    @Test func triggerText() {
        let trigger = SQLiteTrigger("CREATE TRIGGER t AFTER INSERT ON orders BEGIN UPDATE x SET y = 1; END")
        #expect(trigger.timing == "AFTER" && trigger.event == "INSERT")
        #expect(trigger.statement == "BEGIN UPDATE x SET y = 1; END")
        #expect(SQLiteAffinity("VARCHAR(20)") == .text && SQLiteAffinity("BIGINT") == .integer
            && SQLiteAffinity("") == .blob && SQLiteAffinity("DECIMAL(10,2)") == .numeric)
        #expect(SQLiteValue.text(10) == "10.0" && SQLiteValue.text(2.5) == "2.5")
    }
}
