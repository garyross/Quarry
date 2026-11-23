import AppKit
import QuarryKit

/// Self-test: CSV, JSON and XML export (S-042).
extension SelfTest {
    static func dataExport(session: Session) async {
        session.database = "quarry_demo"
        await session.currentLoad?.value
        let folder = URL(filePath: NSTemporaryDirectory())

        func export(_ exporter: Exporter, to name: String) async -> String? {
            let url = folder.appending(path: name)
            try? FileManager.default.removeItem(at: url)
            await exporter.start(to: url)?.value
            defer { try? FileManager.default.removeItem(at: url) }
            return try? String(contentsOf: url, encoding: .utf8)
        }

        // Tables as CSV: a header per table, every row, a blank line between.
        session.view = .content
        session.selectedObjectID = "table:customers"
        session.sidebarSelection = []
        await session.currentLoad?.value
        session.requestExport(["table:customers", "table:products"])
        guard let tables = session.exporter else { return check("S-042 Export… opens the sheet", false) }
        tables.format = .csv
        check("S-042 CSV lists tables and views only, the clicked ones checked",
              tables.dataRows.allSatisfy(\.hasData) && tables.dataTables == ["customers", "products"]
              && tables.fileName == "quarry_demo.csv" && tables.source == .tables,
              "\(tables.dataTables) \(tables.fileName)")
        let customers = await firstValue(in: session, "SELECT COUNT(*) FROM quarry_demo.customers").flatMap(Int.init) ?? -1
        let products = await firstValue(in: session, "SELECT COUNT(*) FROM quarry_demo.products").flatMap(Int.init) ?? -1
        let csv = await export(tables, to: "quarry-selftest.csv") ?? ""
        let lines = csv.components(separatedBy: "\n")
        check("S-042 CSV has each table's header and rows",
              lines.first?.hasPrefix("\"id\",") == true && lines.count == customers + products + 2 + 1 + 1
              && tables.finishedText == "Exported 2 items to quarry-selftest.csv",
              "\(lines.count) lines for \(customers)+\(products) rows; \(tables.error ?? tables.finishedText ?? "")")
        session.exporter = nil

        // Content's rows under a filter, as JSON: exactly the filtered rows, typed.
        session.selectedObjectID = "table:orders"
        await session.currentLoad?.value
        session.content.filter.draft = FilterTree(RowFilter(column: "id", op: .between, value: "2", secondValue: "6"))
        session.applyFilter()
        await session.currentLoad?.value
        session.requestExport()
        guard let filtered = session.exporter else { return check("S-042 Export… opens on Content", false) }
        filtered.source = .content
        check("S-042 choosing Filtered Content switches SQL to CSV",
              filtered.format == .csv && filtered.title(of: .content) == "Filtered Content of “orders”"
              && filtered.fileName == "orders.csv", "\(filtered.format) \(filtered.title(of: .content))")
        filtered.format = .json
        let expected = await firstValue(in: session, "SELECT COUNT(*) FROM quarry_demo.orders WHERE id BETWEEN 2 AND 6")
            .flatMap(Int.init) ?? -1
        let json = await export(filtered, to: "quarry-selftest.json") ?? ""
        let objects = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]]
        check("S-042 filtered content as JSON: the filtered rows, ids as numbers",
              expected > 0 && objects?.count == expected && objects?.first?["id"] is Int
              && filtered.finishedText == "Exported \(expected) rows to quarry-selftest.json",
              "\(objects?.count ?? -1) rows; \(filtered.error ?? filtered.finishedText ?? "")")
        session.exporter = nil
        session.content.filter.draft = FilterTree()
        session.applyFilter()
        await session.currentLoad?.value

        // The query result, from the results' row menu, as XML with NULL marked.
        session.view = .query
        session.query.text = "SELECT id, NULL AS note, 'a & b' AS text FROM customers ORDER BY id LIMIT 3"
        session.runAll()
        await session.currentLoad?.value
        session.requestExportResults()
        guard let result = session.exporter else { return check("S-042 Export Results… opens the sheet", false) }
        check("S-042 Export Results… starts on Query Result as CSV",
              result.source == .result && result.format == .csv && result.fileName == "Query Result.csv")
        result.format = .xml
        let xml = await export(result, to: "quarry-selftest.xml") ?? ""
        check("S-042 the query result as XML parses, with NULL as xsi:nil",
              XMLParser(data: Data(xml.utf8)).parse() && xml.contains("<resultset statement=\"SELECT id")
              && xml.components(separatedBy: "<row>").count == 4 && xml.contains("xsi:nil=\"true\"")
              && xml.contains("a &amp; b"), String(xml.prefix(300)))
        session.exporter = nil
        session.view = .content
    }
}
