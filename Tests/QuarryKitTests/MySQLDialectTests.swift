import Foundation
import Testing
@testable import QuarryKit

/// A `SQLRunner` that records each statement and answers with a canned result:
/// the dialect's second adapter, so its catalog reads run without a server.
private final class RecordingRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String] = []
    private let answer: @Sendable (String) -> StatementResult

    init(_ answer: @escaping @Sendable (String) -> StatementResult = { _ in .rows([], []) }) { self.answer = answer }

    var statements: [String] { lock.withLock { sent } }

    var run: SQLRunner {
        { [self] sql in
            lock.withLock { sent.append(sql) }
            return answer(sql)
        }
    }
}

extension StatementResult {
    static func rows(_ names: [String], _ rows: [[String?]]) -> StatementResult {
        StatementResult(sql: "", columns: names.map { ResultColumn(name: $0) },
                        rows: rows.map { $0.map { $0.map(CellValue.text) ?? .null } }, affectedRows: nil, duration: .zero)
    }
}

@Suite("MySQL dialect")
struct MySQLDialectTests {
    let dialect = MySQLDialect()

    @Test func catalogReadsSendTheStatementsQuarryAlwaysSent() async throws {
        let runner = RecordingRunner()
        _ = try await dialect.databases(runner.run)
        _ = try await dialect.tablesAndViews(in: "shop", runner.run)
        _ = try await dialect.routines(in: "shop", runner.run)
        _ = try await dialect.fields(of: "orders", in: "shop", runner.run)
        _ = try await dialect.indexes(of: "orders", in: "shop", runner.run)
        _ = try await dialect.triggers(of: "orders", in: "shop", runner.run)
        _ = try await dialect.triggerNames(in: "shop", runner.run)
        _ = try await dialect.tableStatus(of: "orders", in: "shop", runner.run)
        _ = try await dialect.createStatement(of: DBObject(name: "totals", kind: .view), in: "shop", runner.run)
        _ = await dialect.latestForeignKeyError(runner.run)
        #expect(runner.statements == [
            "SHOW DATABASES",
            "SHOW FULL TABLES FROM `shop`",
            "SELECT ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = 'shop' ORDER BY ROUTINE_NAME",
            "SHOW FULL COLUMNS FROM `shop`.`orders`",
            "SHOW INDEX FROM `shop`.`orders`",
            "SHOW TRIGGERS FROM `shop` WHERE `Table` = 'orders'",
            "SELECT TRIGGER_NAME AS n FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = 'shop'",
            "SHOW TABLE STATUS FROM `shop` WHERE Name = 'orders'",
            "SHOW CREATE VIEW `shop`.`totals`",
            "SHOW ENGINE INNODB STATUS",
        ])
    }

    @Test func readsTheAnswers() async throws {
        let runner = RecordingRunner { sql in
            if sql.hasPrefix("SHOW FULL TABLES") {
                return .rows(["Tables_in_shop", "Table_type"], [["orders", "BASE TABLE"], ["totals", "VIEW"], ["audit", "SEQUENCE"], ["junk", "TEMPORARY"]])
            }
            if sql.hasPrefix("SHOW FULL COLUMNS") {
                return .rows(["Field", "Type", "Collation", "Null", "Key", "Default", "Extra", "Privileges", "Comment"],
                             [["id", "int(11)", nil, "NO", "PRI", nil, "auto_increment", "", "the key"]])
            }
            if sql.hasPrefix("SHOW CREATE") {
                return .rows(["View", "Create View", "character_set_client"], [["totals", "CREATE VIEW x", "utf8mb4"]])
            }
            return .rows([], [])
        }
        let objects = try await dialect.tablesAndViews(in: "shop", runner.run)
        #expect(objects == [DBObject(name: "audit", kind: .table), DBObject(name: "orders", kind: .table), DBObject(name: "totals", kind: .view)])
        let fields = try await dialect.fields(of: "orders", in: "shop", runner.run)
        #expect(fields == [FieldInfo(name: "id", fullType: "int(11)", isNullable: false, key: "PRI", defaultValue: nil,
                                     extra: "auto_increment", collation: nil, comment: "the key")])
        let create = try await dialect.createStatement(of: DBObject(name: "totals", kind: .view), in: "shop", runner.run)
        #expect(create == "CREATE VIEW x")
    }

    /// One read for Show Create Statement and the agents' create_statement: a
    /// trigger's text is in SHOW CREATE TRIGGER's "SQL Original Statement".
    @Test func createStatementReadsEveryKindsColumn() async throws {
        let runner = RecordingRunner { sql in
            sql.hasPrefix("SHOW CREATE TRIGGER")
                ? .rows(["Trigger", "sql_mode", "SQL Original Statement"], [["t", "", "CREATE TRIGGER t ..."]])
                : sql.hasPrefix("SHOW CREATE EVENT") ? .rows(["Event"], [])
                : .rows(["Procedure", "sql_mode", "Create Procedure"], [["p", "", "CREATE PROCEDURE p ()"]])
        }
        #expect(try await dialect.createStatement(kind: "trigger", of: "t", in: "d", runner.run) == "CREATE TRIGGER t ...")
        #expect(try await dialect.createStatement(kind: "event", of: "e", in: "d", runner.run) == nil)
        #expect(try await dialect.createStatement(of: DBObject(name: "p", kind: .procedure), in: "d", runner.run)
            == "CREATE PROCEDURE p ()")
        #expect(runner.statements == ["SHOW CREATE TRIGGER `d`.`t`", "SHOW CREATE EVENT `d`.`e`", "SHOW CREATE PROCEDURE `d`.`p`"])
    }

    @Test func foreignKeysAndEnginesReadInformationSchema() async throws {
        let runner = RecordingRunner { sql in
            sql.contains("KEY_COLUMN_USAGE")
                ? .rows(["name", "columns", "ref_db", "ref_table", "ref_columns", "on_update", "on_delete"],
                        [["fk_order", "order_id", "shop", "orders", "id", "CASCADE", "RESTRICT"]])
                : .rows(["name", "engine"], [["orders", "InnoDB"]])
        }
        let keys = try await dialect.foreignKeys(of: "items", in: "shop", runner.run)
        #expect(keys.map(\.name) == ["fk_order"])
        #expect(keys.first?.onUpdate == "CASCADE")
        #expect(runner.statements[0].contains("WHERE k.TABLE_SCHEMA = 'shop' AND k.TABLE_NAME = 'items'"))
        let engines = try await dialect.tableEngines(in: "shop", runner.run)
        #expect(engines == ["orders": "InnoDB"])
    }

    @Test func statements() {
        #expect(dialect.useSQL("a`b") == "USE `a``b`")
        #expect(dialect.currentDatabaseSQL == "SELECT DATABASE()")
        #expect(dialect.countSQL(table: "t", database: "d", where: "x = 1") == "SELECT COUNT(*) FROM `d`.`t` WHERE x = 1")
        #expect(dialect.viewEncodingSQL(.utf8mb4) == "SET NAMES utf8mb4")
        #expect(dialect.readOnlyBeginSQL == "START TRANSACTION READ ONLY")
        #expect(dialect.explainSQL("SELECT 1") == "EXPLAIN SELECT 1")
        #expect(dialect.sampleSQL(table: "t", database: "d", limit: 10) == "SELECT * FROM `d`.`t` LIMIT 10")
        #expect(dialect.variablesSQL(named: ["port", "read_only"]) == "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('port', 'read_only')")
        #expect(dialect.processListSQL(full: true) == "SHOW FULL PROCESSLIST")
        #expect(dialect.killSQL(42, connection: false) == "KILL QUERY 42")
        #expect(dialect.killSQL(42, connection: true) == "KILL 42")
        #expect(dialect.isInMemory("INFORMATION_SCHEMA"))
        #expect(!dialect.isInMemory("mysql"))
    }
}
