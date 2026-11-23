import Foundation
import Testing
@testable import QuarryKit

struct SavedQueryFileTests {
    private let items = [
        SavedQueryFile.Item(name: "Big spenders", query: "SELECT name\nFROM customers\nWHERE spent > 1000;"),
        SavedQueryFile.Item(name: "Ünïcode ✓", query: "SELECT '☃' AS snow"),
    ]

    @Test func exportThenImportGivesTheSameQueries() throws {
        let data = try SavedQueryFile.encode(items)
        #expect(try SavedQueryFile.decode(data) == items)
    }

    @Test func exportIsSequelProsFormat() throws {
        let data = try SavedQueryFile.encode(items)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["format"] as? String == "query favorites")
        #expect(plist["version"] as? Int == 1)
        let list = try #require(plist["queryFavorites"] as? [[String: String]])
        #expect(list.first == ["name": "Big spenders", "query": "SELECT name\nFROM customers\nWHERE spent > 1000;"])
    }

    @Test func importsASequelProFile() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>encrypted</key><false/>
        <key>format</key><string>query favorites</string>
        <key>queryFavorites</key><array>
          <dict><key>name</key><string>Tables</string><key>query</key><string>SHOW TABLES</string></dict>
          <dict><key>name</key><string>Empty</string><key>query</key><string>  </string></dict>
          <dict><key>query</key><string>SELECT 1</string></dict>
        </array>
        <key>version</key><integer>1</integer>
        </dict></plist>
        """
        let decoded = try SavedQueryFile.decode(Data(xml.utf8))
        #expect(decoded == [.init(name: "Tables", query: "SHOW TABLES"), .init(name: "SELECT 1", query: "SELECT 1")])
    }

    @Test func aFileWithNoQueriesSaysSo() throws {
        let empty = try SavedQueryFile.encode([])
        #expect(throws: SavedQueryFile.ImportError.noQueries) { try SavedQueryFile.decode(empty) }
        #expect(throws: SavedQueryFile.ImportError.self) { try SavedQueryFile.decode(Data("not a plist".utf8)) }
        #expect(throws: SavedQueryFile.ImportError.noQueries) { try SavedQueryFile.sqlItem(fileName: "a.sql", text: "\n") }
    }

    @Test func anSQLFileIsOneQueryNamedAfterTheFile() throws {
        let item = try SavedQueryFile.sqlItem(fileName: "Monthly report.sql", text: "SELECT 1;\nSELECT 2;")
        #expect(item == .init(name: "Monthly report", query: "SELECT 1;\nSELECT 2;"))
    }

    @Test func defaultNameIsTheFirstWordsCutAtAWord() {
        #expect(SavedQueryFile.defaultName(for: "SELECT *\n  FROM t") == "SELECT * FROM t")
        #expect(SavedQueryFile.defaultName(for: "  ") == "New Query")
        let long = "SELECT customer_id, SUM(total) AS spent FROM orders GROUP BY customer_id"
        #expect(SavedQueryFile.defaultName(for: long) == "SELECT customer_id, SUM(total) AS spent…")
    }

    @Test func namesInUseGetANumber() {
        #expect(SavedQueryFile.uniqueName("Report", among: ["Other"]) == "Report")
        #expect(SavedQueryFile.uniqueName("Report", among: ["report", "Report 2"]) == "Report 3")
        #expect(SavedQueryFile.copyName("Report", among: ["Report", "Report copy"]) == "Report copy 2")
    }

    @Test func mergingSkipsExactCopiesAndRenamesClashes() {
        let existing = [SavedQueryFile.Item(name: "A", query: "SELECT 1")]
        let incoming = [
            SavedQueryFile.Item(name: "A", query: "SELECT 1"),
            SavedQueryFile.Item(name: "A", query: "SELECT 2"),
            SavedQueryFile.Item(name: "A", query: "SELECT 3"),
        ]
        #expect(SavedQueryFile.merging(incoming, into: existing) == [
            .init(name: "A 2", query: "SELECT 2"), .init(name: "A 3", query: "SELECT 3"),
        ])
    }
}
