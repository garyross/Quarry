import Foundation
import Testing
@testable import QuarryKit

/// S-065: MCP Activity's filter, CSV and statement summary.
struct AgentActivityTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func record(_ hoursAgo: Double, tool: String = "read_query", token: String = "Automatic", statement: String = "SELECT 1",
                status: ActivityRecord.Status = .ok) -> ActivityRecord {
        ActivityRecord(date: now.addingTimeInterval(-hoursAgo * 3600), client: "claude-code 2.1", token: token, connection: "Local",
                       database: "quarry_demo", tool: tool, statement: statement, status: status, duration: 0.012)
    }

    @Test func filtersByRangeTokenAndWords() {
        let records = [record(1), record(30, token: "CI"), record(24 * 10, statement: "DELETE FROM orders", status: .denied),
                       record(24 * 40)]
        #expect(ActivityFilter(range: .day).apply(records, now: now).count == 1)
        #expect(ActivityFilter(range: .week).apply(records, now: now).count == 2)
        #expect(ActivityFilter(range: .month).apply(records, now: now).count == 3)
        #expect(ActivityFilter(range: .all).apply(records, now: now).count == 4)
        #expect(ActivityFilter(token: "CI").apply(records, now: now).map(\.token) == ["CI"])
        #expect(ActivityFilter(text: "delete denied").apply(records, now: now).count == 1)
        #expect(ActivityFilter(text: "orders select").apply(records, now: now).isEmpty)
        // Newest first.
        #expect(ActivityFilter().apply(records.reversed(), now: now).first?.date == records[0].date)
    }

    @Test func csvQuotesFields() {
        let text = AgentActivity.csv([record(0, statement: "SELECT \"a\", b\nFROM t")])
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[0] == "Time,Client,Token,Connection,Database,Tool,Statement,Status,Message,Duration (ms)")
        #expect(text.contains("\"SELECT \"\"a\"\", b\nFROM t\",OK,,12"))
        #expect(text.hasSuffix("\r\n"))
    }

    @Test func summaryLeavesOutConnectionAndDatabase() {
        let summary = AgentActivity.summary(["connection": "Local", "database": "x", "table": "customers", "limit": 5])
        #expect(summary == "limit: 5, table: customers")
    }

    @Test func durationText() {
        #expect(record(0).durationText == "12 ms")
        var slow = record(0)
        slow.duration = 1.43
        #expect(slow.durationText == "1.4 s")
    }
}
