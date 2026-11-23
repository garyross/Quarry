import Foundation
import Testing
@testable import QuarryKit

/// S-073: agents on SQLite files: the read rules for the SQLite dialect, and an
/// agent's connection that SQLite itself keeps from writing.
struct AgentSQLiteRulesTests {
    @Test(arguments: ["SELECT * FROM customers", "with t as (select 1) select * from t", "VALUES (1)",
                      "EXPLAIN QUERY PLAN SELECT * FROM orders", "PRAGMA table_info(orders)", "pragma main.index_list('orders')",
                      "PRAGMA journal_mode", "PRAGMA foreign_key_check", "PRAGMA integrity_check", "PRAGMA quick_check(5)",
                      "SELECT 'C:\\' AS path", "SELECT * FROM pragma_table_info('orders')"])
    func readsOnAFile(_ sql: String) {
        #expect(AgentSQL.readProblem(sql, engine: .sqlite) == nil)
    }

    @Test(arguments: ["DELETE FROM customers", "INSERT INTO notes VALUES ('x')", "CREATE TABLE x (a)", "VACUUM",
                      "BEGIN", "REINDEX", "ANALYZE", "SHOW TABLES", "PRAGMA optimize", "PRAGMA wal_checkpoint",
                      "PRAGMA journal_mode = WAL", "PRAGMA query_only = OFF", "PRAGMA query_only(0)", "PRAGMA foreign_keys=0",
                      "pragma main.user_version = 3"])
    func notReadsOnAFile(_ sql: String) {
        #expect(AgentSQL.readProblem(sql, engine: .sqlite) != nil)
    }

    @Test func otherFilesAreRefusedForReadsAndWrites() {
        for sql in ["ATTACH 'other.db' AS other", "attach database '/tmp/x.db' as x", "DETACH other"] {
            #expect(AgentSQL.readProblem(sql, engine: .sqlite) == AgentSQL.attachProblem)
            #expect(AgentSQL.statementProblem(sql, engine: .sqlite) == AgentSQL.attachProblem)
        }
        #expect(AgentSQL.readProblem("SELECT load_extension('evil')", engine: .sqlite)?.contains("load_extension") == true)
        #expect(AgentSQL.statementProblem("SELECT LOAD_EXTENSION ('evil')", engine: .sqlite)?.contains("load_extension") == true)
        #expect(AgentSQL.statementProblem("VACUUM INTO '/tmp/copy.db'", engine: .sqlite)?.contains("VACUUM INTO") == true)
        #expect(AgentSQL.statementProblem("PRAGMA writable_schema = ON", engine: .sqlite)?.contains("writable_schema") == true)
        // Writes that stay in the file are write_query's to run.
        #expect(AgentSQL.statementProblem("VACUUM", engine: .sqlite) == nil)
        #expect(AgentSQL.statementProblem("PRAGMA journal_mode = WAL", engine: .sqlite) == nil)
        #expect(AgentSQL.statementProblem("UPDATE notes SET body = 'ATTACH'", engine: .sqlite) == nil)
    }

    @Test func aBackslashIsOrdinaryInSQLiteText() {
        // In SQLite 'C:\' is a whole string, so the statement after it is seen.
        #expect(AgentSQL.readProblem("SELECT 'C:\\'; ATTACH 'x' AS x", engine: .sqlite) != nil)
        #expect(AgentSQL.readProblem("SELECT 'it''s'", engine: .sqlite) == nil)
        // MySQL keeps its backslash escapes.
        #expect(AgentSQL.readProblem("SELECT 'it\\'s'", engine: .mysql) == nil)
    }

    @Test func pragmaMessagesSayWhatToDo() {
        #expect(AgentSQL.readProblem("PRAGMA journal_mode = WAL", engine: .sqlite)
            == "PRAGMA journal_mode = … changes a setting. Use write_query for it.")
        #expect(AgentSQL.readProblem("PRAGMA optimize", engine: .sqlite)
            == "PRAGMA optimize may change the file, so read_query doesn’t run it. Use write_query for it.")
    }
}

@Suite struct AgentSQLiteConnectionTests {
    @Test func aReadConnectionCantWriteOrAttach() async throws {
        let url = try SQLiteDialectTests.fixture()
        let client = try await SQLiteDialectTests.open(url, readOnly: true)
        try await client.restrictForAgent(readOnly: true)
        let rows = try await client.agentRead("SELECT count(*) FROM customers", in: "main", offset: 0, limit: 1)
        #expect(rows.rows.first?.first?.plainText == "6")
        await #expect(throws: (any Error).self) { _ = try await client.agentWrite("DELETE FROM notes", in: nil) }
        await #expect(throws: (any Error).self) { _ = try await client.run("ATTACH '\(url.path)' AS again") }
        let queryOnly = try await client.run("PRAGMA query_only")
        #expect(queryOnly.rows.first?.first?.plainText == "1")
        await client.close()
    }

    @Test func aWriteConnectionWritesButCantAttach() async throws {
        let url = try SQLiteDialectTests.fixture()
        let client = try await SQLiteDialectTests.open(url)
        try await client.restrictForAgent(readOnly: false)
        let changed = try await client.agentWrite("INSERT INTO notes VALUES ('from an agent')", in: nil)
        #expect(changed.affectedRows == 1)
        await #expect(throws: (any Error).self) { _ = try await client.run("ATTACH '\(url.path)' AS again") }
        await client.close()
    }

    @Test func sizesSettingsAndTriggers() async throws {
        let url = try SQLiteDialectTests.fixture()
        let client = try await SQLiteDialectTests.open(url, readOnly: true)
        let dialect = SQLiteDialect()
        let sizes = try await client.run(dialect.tableSizesSQL(in: "main"))
        let names = sizes.rows.indices.compactMap { sizes.string($0, "name") }
        #expect(Set(names) == ["customers", "events", "notes", "order_items", "orders", "products", "settings"])
        let orders = sizes.rows.indices.first { sizes.string($0, "name") == "orders" }
        // orders has two indexes of its own.
        #expect(orders.flatMap { sizes.string($0, "idx") }.flatMap(Int.init).map { $0 >= 8192 } == true)
        #expect(try await client.run(dialect.tableSizesFallbackSQL(in: "main")!).rows.count == names.count)

        let settings = try await client.run(dialect.fileSettingsSQL!)
        let values = Dictionary(uniqueKeysWithValues: settings.rows.indices.compactMap { row in
            settings.string(row, "Variable_name").map { ($0, settings.string(row, "Value") ?? "") }
        })
        #expect(Set(values.keys) == Set(SQLiteDialect.fileSettings))
        #expect(values["encoding"] == "UTF-8" && values["foreign_keys"] == "1")

        let triggers = try await client.run(dialect.agentTriggersSQL(in: "main"))
        let trigger = SQLiteTrigger(triggers.string(0, "statement") ?? "")
        #expect(triggers.string(0, "name") == "products_stock_check" && trigger.timing == "BEFORE" && trigger.event == "UPDATE")
        await client.close()
    }
}
