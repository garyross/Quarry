import Testing
@testable import QuarryKit

struct TableOperationTests {
    @Test func statementAndTitles() {
        #expect(TableOperation.optimize.sql(["a", "b`c"], in: "db") == "OPTIMIZE TABLE `db`.`a`, `db`.`b``c`")
        #expect(TableOperation.check.menuTitle(tables: 1, views: 0) == "Check Table")
        #expect(TableOperation.check.menuTitle(tables: 0, views: 1) == "Check View")
        #expect(TableOperation.check.menuTitle(tables: 2, views: 1) == "Check 3 Items")
        #expect(TableOperation.checksum.menuTitle(tables: 3, views: 0) == "Checksum 3 Tables")
        #expect(TableOperation.check.worksOnViews(.mysql) && !TableOperation.repair.worksOnViews(.mysql) && !TableOperation.check.worksOnViews(.sqlite))
    }

    @Test func resultsGroupByTable() {
        let rows: [(table: String, type: String, text: String)] = [
            ("db.a", "note", "Table does not support optimize, doing recreate + analyze instead"),
            ("db.a", "status", "OK"),
            ("db.v", "Error", "'db.v' is not of type 'BASE TABLE'"),
            ("db.v", "status", "Operation failed"),
        ]
        let results = TableOperation.optimize.results(tables: ["a", "v", "gone"], in: "db", rows: rows)
        #expect(results.map(\.message) == ["OK", "'db.v' is not of type 'BASE TABLE'", "No result"])
        #expect(results.map(\.severity) == [.ok, .error, .warning])
        let message = TableOperation.optimize.alertMessage(results)
        #expect(message.hasPrefix("2 of 3 tables have problems.\n\na: OK\nv: "))
        #expect(TableOperation.optimize.alertTitle(results) == "Optimize 3 Tables")
    }

    @Test func oneTableAndAllOK() {
        let ok = [TableCheck(table: "orders", severity: .ok, message: "OK")]
        #expect(TableOperation.check.alertTitle(ok) == "Check “orders”")
        #expect(TableOperation.check.alertMessage(ok) == "OK")
        let two = ok + [TableCheck(table: "items", severity: .ok, message: "Table is already up to date")]
        #expect(TableOperation.analyze.alertMessage(two) == "All 2 tables are OK.\n\norders: OK\nitems: Table is already up to date")
        let many = (1...5).map { TableCheck(table: "t\($0)", severity: .ok, message: "OK") }
        #expect(TableOperation.check.alertMessage(many, limit: 2).hasSuffix("t2: OK\n…and 3 more"))
    }

    @Test func checksums() {
        let results = TableOperation.checksums(tables: ["a", "b"], in: "db", rows: [("db.a", "144536216"), ("db.b", nil)])
        #expect(results.map(\.message) == ["144536216", "No checksum: the table doesn’t exist"])
        #expect(TableOperation.checksum.alertMessage(results) == "a: 144536216\nb: No checksum: the table doesn’t exist")
    }
}
