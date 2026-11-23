import Foundation
import Testing
@testable import QuarryKit

struct QueryHistoryTests {
    @Test func addingPutsTheQueryOnTopWithoutDuplicates() {
        var entries: [String] = []
        entries = QueryHistory.adding("SELECT 1", to: entries, limit: 20)
        entries = QueryHistory.adding("SELECT 2", to: entries, limit: 20)
        entries = QueryHistory.adding("SELECT 1", to: entries, limit: 20)
        #expect(entries == ["SELECT 1", "SELECT 2"])
    }

    @Test func addingKeepsTheLastN() {
        var entries: [String] = []
        for n in 1...25 { entries = QueryHistory.adding("SELECT \(n)", to: entries, limit: QueryHistory.defaultLimit) }
        #expect(entries.count == 20)
        #expect(entries.first == "SELECT 25")
        #expect(entries.last == "SELECT 6")
        // A smaller limit trims at the next run.
        entries = QueryHistory.adding("SELECT 26", to: entries, limit: 3)
        #expect(entries == ["SELECT 26", "SELECT 25", "SELECT 24"])
    }

    @Test func theLimitStaysBetweenOneAndAHundred() {
        #expect(QueryHistory.clampedLimit(0) == 1)
        #expect(QueryHistory.clampedLimit(500) == 100)
        let many = (1...150).reduce(into: [String]()) { $0 = QueryHistory.adding("q\($1)", to: $0, limit: 500) }
        #expect(many.count == 100)
    }

    @Test func anEntryJoinsTheRunsStatements() {
        #expect(QueryHistory.entry(for: ["SELECT 1;", "  \n", "SELECT 2 ;\n"]) == "SELECT 1;\nSELECT 2")
        #expect(QueryHistory.entry(for: ["  ", ";"]) == nil)
        #expect(QueryHistory.entry(for: []) == nil)
    }

    @Test func searchMatchesEveryWordIgnoringCase() {
        let entries = ["SELECT * FROM customers", "select name from orders", "SHOW TABLES"]
        #expect(QueryHistory.matches("", in: entries) == entries)
        #expect(QueryHistory.matches("from", in: entries) == ["SELECT * FROM customers", "select name from orders"])
        #expect(QueryHistory.matches("select ORDERS", in: entries) == ["select name from orders"])
        #expect(QueryHistory.matches("nothing", in: entries).isEmpty)
    }

    @Test func summaryAndScript() {
        #expect(QueryHistory.summary("SELECT *\n  FROM t") == "SELECT * FROM t")
        #expect(QueryHistory.script(["SELECT 2", "SELECT 1"]) == "SELECT 1;\nSELECT 2;\n")
    }

    @Test func stepperGoesOlderThenNewerAndStopsAtTheEnds() {
        var stepper = HistoryStepper()
        #expect(stepper.next(count: 3) == nil)
        #expect(stepper.previous(count: 3) == 0)
        #expect(stepper.previous(count: 3) == 1)
        #expect(stepper.previous(count: 3) == 2)
        #expect(stepper.previous(count: 3) == nil)
        #expect(stepper.offset == 2)
        #expect(stepper.next(count: 3) == 1)
        stepper.reset()
        #expect(stepper.previous(count: 0) == nil)
        #expect(stepper.offset == -1)
    }
}
