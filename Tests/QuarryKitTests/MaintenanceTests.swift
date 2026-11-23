import Foundation
import Testing
@testable import QuarryKit
import QuarryTestSupport

@Suite("Database maintenance")
struct MaintenanceTests {
    @Test func checkVerdicts() {
        #expect(TableCheck.parse(table: "t", rows: [("status", "OK")]).severity == .ok)
        #expect(TableCheck.parse(table: "t", rows: [("status", "Table is already up to date")]).severity == .ok)
        let crashed = TableCheck.parse(table: "t", rows: [("warning", "Table is marked as crashed"),
                                                          ("error", "Found 3 keys of 4"), ("status", "Corrupt")])
        #expect(crashed.severity == .error)
        #expect(crashed.message == "Table is marked as crashed")
        let failed = TableCheck.parse(table: "t", rows: [("status", "Operation failed")])
        #expect(failed.severity == .error && failed.message == "Operation failed")
        #expect(TableCheck.parse(table: "t", rows: [("note", "The storage engine doesn't support check")]).severity == .ok)
    }

    @Test func utf8mb3Names() {
        #expect(Charsets.isUTF8MB3("utf8mb3"))
        #expect(Charsets.isUTF8MB3("utf8"))
        #expect(Charsets.isUTF8MB3("utf8_general_ci"))
        #expect(Charsets.isUTF8MB3("utf8mb3_uca1400_ai_ci"))
        #expect(!Charsets.isUTF8MB3("utf8mb4"))
        #expect(!Charsets.isUTF8MB3("utf8mb4_unicode_ci"))
        #expect(Charsets.utf8mb4Equivalent(of: "utf8mb3_unicode_ci") == "utf8mb4_unicode_ci")
        #expect(Charsets.utf8mb4Equivalent(of: "utf8_general_ci") == "utf8mb4_general_ci")
        #expect(Charsets.utf8mb4Equivalent(of: "utf8mb3_uca1400_ai_ci") == "utf8mb4_uca1400_ai_ci")
    }

    @Test func collationReport() {
        let columns = [
            ColumnCharset(table: "a", column: "x", charset: "utf8mb4", collation: "utf8mb4_unicode_ci"),
            ColumnCharset(table: "a", column: "y", charset: "utf8mb4", collation: "utf8mb4_unicode_ci"),
            ColumnCharset(table: "b", column: "z", charset: "utf8mb3", collation: "utf8mb3_general_ci"),
        ]
        let tables = [TableStat(name: "a", collation: "utf8mb4_unicode_ci"), TableStat(name: "b"),
                      TableStat(name: "c", collation: "utf8mb3_bin"), TableStat(name: "v", isView: true, collation: "utf8mb3_bin")]
        let report = CollationReport(database: "d", defaultCharset: "utf8mb4", defaultCollation: "utf8mb4_unicode_ci",
                                     columns: columns, tables: tables)
        #expect(report.uses.map(\.collation) == ["utf8mb4_unicode_ci", "utf8mb3_general_ci"])
        #expect(report.uses[0].columns == 2 && report.uses[1].isUTF8MB3)
        #expect(report.tablesToConvert.map(\.table) == ["b", "c"])
        #expect(report.conversionSQL?.contains("ALTER TABLE `d`.`b` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;") == true)
        #expect(report.conversionSQL?.contains("ALTER DATABASE") == false)

        let clean = CollationReport(database: "d", defaultCharset: "utf8mb4", defaultCollation: "utf8mb4_unicode_ci",
                                    columns: Array(columns.prefix(2)), tables: [tables[0]])
        #expect(clean.conversionSQL == nil)
    }

    @Test func autoIncrementRange() {
        #expect(AutoIncrementColumn(table: "t", column: "id", type: "tinyint(3) unsigned", next: 255).maximum == 255)
        #expect(AutoIncrementColumn(table: "t", column: "id", type: "int(11)", next: 1).maximum == 2_147_483_647)
        #expect(AutoIncrementColumn(table: "t", column: "id", type: "varchar(3)", next: 1).maximum == nil)
    }

    private func input(_ tables: [TableStat], keys: Set<String>? = nil, columns: [ColumnCharset] = [],
                       auto: [AutoIncrementColumn] = [], routinesError: DatabaseError? = nil) -> HealthInput {
        HealthInput(overview: DatabaseOverview(name: "d", charset: "utf8mb4", collation: "utf8mb4_unicode_ci",
                                               objects: tables, routineCount: routinesError == nil ? 0 : nil,
                                               routinesError: routinesError),
                    columns: columns, tablesWithPrimaryKey: keys ?? Set(tables.map(\.name)), autoIncrements: auto, isMariaDB: true)
    }

    @Test func healthyDatabase() {
        let findings = HealthCheck.run(input([TableStat(name: "a")]))
        #expect(findings.map(\.id) == ["ok"])
    }

    @Test func healthFindings() {
        let tables = [TableStat(name: "a", engine: "MyISAM"), TableStat(name: "b"),
                      TableStat(name: "big", dataBytes: 40 << 20, freeBytes: 30 << 20)]
        let findings = HealthCheck.run(input(
            tables, keys: ["a", "big"],
            columns: [ColumnCharset(table: "a", column: "x", charset: "utf8mb3", collation: "utf8mb3_general_ci"),
                      ColumnCharset(table: "b", column: "y", charset: "latin1", collation: "latin1_swedish_ci")],
            auto: [AutoIncrementColumn(table: "a", column: "id", type: "tinyint unsigned", next: 250)],
            routinesError: DatabaseError(message: "Column count of mysql.proc is wrong. … Please use mariadb-upgrade", code: 1558)))
        let ids = findings.map(\.id)
        #expect(ids.first == "system-tables")
        #expect(Set(ids) == ["system-tables", "auto-increment:a.id", "primary-key", "engine", "utf8mb3",
                             "legacy-charset", "mixed-collations", "fragmented"])
        #expect(findings.first { $0.id == "primary-key" }?.tables == ["b"])
        #expect(findings.first { $0.id == "engine" }?.sql == "ALTER TABLE `d`.`a` ENGINE=InnoDB;")
        #expect(findings.first { $0.id == "fragmented" }?.sql == "OPTIMIZE TABLE `d`.`big`;")
        #expect(findings.first { $0.id == "system-tables" }?.detail.contains("mariadb-upgrade -u root -p --upgrade-system-tables") == true)
        // Worst first.
        #expect(findings.map(\.severity) == findings.map(\.severity).sorted(by: >))
    }
}

@Suite("Database maintenance on the test server", .enabled(if: TestServer.isRunning))
struct MaintenanceServerTests {
    @Test func overviewAndHealth() async throws {
        let client = try await DatabaseClient.connect(TestServer.details)
        let demo = try await client.overview(of: "quarry_demo")
        #expect(demo.tables.count == 5 && demo.viewCount == 1 && demo.routineCount == 2)
        #expect(demo.charset == "utf8mb4")
        #expect(demo.countsLine == "5 tables · 1 view · 2 routines")

        let legacy = try await client.overview(of: "quarry_legacy")
        let findings = HealthCheck.run(try await client.healthInput(for: legacy))
        let ids = Set(findings.map(\.id))
        #expect(ids.isSuperset(of: ["primary-key", "engine", "utf8mb3", "legacy-charset", "auto-increment:counters.id"]), "\(ids)")
        #expect(findings.first { $0.id == "primary-key" }?.tables == ["visits"])

        let report = try await client.collationReport(for: legacy)
        #expect(report.tablesToConvert.map(\.table) == ["notes", "visits"])
        await client.close()
    }

    @Test func checkAndRepair() async throws {
        let client = try await DatabaseClient.connect(TestServer.details)
        let check = try await client.check("orders", in: "quarry_demo")
        #expect(check.severity == .ok, "\(check.message)")
        let legacy = try await client.overview(of: "quarry_legacy")
        let notes = try #require(legacy.tables.first { $0.name == "notes" })
        let repaired = try await client.repair(notes, in: "quarry_legacy")
        #expect(repaired.severity == .ok, "\(repaired.message)")
        let counters = try #require(legacy.tables.first { $0.name == "counters" })
        let rebuilt = try await client.repair(counters, in: "quarry_legacy")
        #expect(rebuilt.severity == .ok && rebuilt.message.hasPrefix("Rebuilt"), "\(rebuilt.message)")
        await client.close()
    }
}
