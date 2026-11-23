import Foundation
import Testing
@testable import QuarryKit

/// S-071: export and import with a SQLite file: quoting, the splitter's
/// SQLite rules, batches, the CSV mapping's SQLite SQL, and a round trip of
/// the fixture through export and import.
@Suite struct SQLiteTransferTests {
    // MARK: Quoting

    @Test func sqliteTextHasNoBackslashEscapes() {
        #expect(SQLQuote.literal("it's", engine: .sqlite) == "'it''s'")
        #expect(SQLQuote.literal("C:\\dir\nnext", engine: .sqlite) == "'C:\\dir\nnext'")
        #expect(SQLQuote.literal("it's", engine: .mysql) == "'it\\'s'")
        #expect(SQLiteDialect().literal("o'k") == "'o''k'")
        let columns = [ResultColumn(name: "id", isPrimaryKey: true), ResultColumn(name: "name")]
        #expect(RowEdit.updateSQL(database: "main", table: "t", columns: columns, row: [.text("1"), .text("a")],
                                  changes: [1: .text("O'Brien \\ co")], engine: .sqlite)
            == "UPDATE `main`.`t` SET `name` = 'O''Brien \\ co' WHERE `id` = '1'")
    }

    // MARK: Splitting

    private func split(_ sql: String, chunk: Int = 1) -> (statements: [String], refused: Int?) {
        var splitter = SQLStreamSplitter(engine: .sqlite)
        let bytes = Array(sql.utf8)
        var out: [[UInt8]] = []
        for start in stride(from: 0, to: bytes.count, by: chunk) {
            out += splitter.append(bytes[start..<min(bytes.count, start + chunk)])
        }
        out += splitter.finish()
        return (out.map { String(decoding: $0, as: UTF8.self) }, splitter.refusedDelimiterLine)
    }

    @Test(arguments: [1, 7, 4096])
    func aTriggerBodyIsOneStatement(chunk: Int) {
        let sql = """
        CREATE TABLE t (a);
        CREATE TRIGGER t_ai AFTER INSERT ON t BEGIN
          UPDATE t SET a = a + 1; SELECT 'x;y';
        END;
        INSERT INTO t VALUES ('C:\\'); INSERT INTO [odd;name] VALUES (1);
        # not a comment in SQLite
        """
        let (statements, refused) = split(sql, chunk: chunk)
        #expect(refused == nil)
        #expect(statements.count == 5)
        #expect(statements[1].hasPrefix("CREATE TRIGGER") && statements[1].hasSuffix("END"))
        #expect(statements[2] == "INSERT INTO t VALUES ('C:\\')")
        #expect(statements[3] == "INSERT INTO [odd;name] VALUES (1)")
        #expect(statements[4] == "# not a comment in SQLite")
    }

    @Test(arguments: [1, 3, 4096])
    func delimiterLinesAreRefusedWithTheirLine(chunk: Int) {
        let sql = "-- a dump\nCREATE TABLE t (a);\n\nDELIMITER ;;\nCREATE TRIGGER x AFTER INSERT ON t BEGIN SELECT 1; END;;\n"
        let (statements, refused) = split(sql, chunk: chunk)
        #expect(refused == 4)
        #expect(statements == ["CREATE TABLE t (a)"])
        #expect(DatabaseClient.delimiterRefusal(line: 4).hasPrefix("Line 4 sets a DELIMITER"))
    }

    // MARK: Batches

    @Test func batchesOpenAndCloseAroundStatements() {
        var batch = SQLiteImportBatch(size: 2)
        #expect(batch.before("PRAGMA foreign_keys = OFF").isEmpty)
        #expect(batch.after() == nil)
        #expect(batch.before("CREATE TABLE t (a)") == ["BEGIN"])
        #expect(batch.after() == nil)
        #expect(batch.before("INSERT INTO t VALUES (1)").isEmpty)
        #expect(batch.after() == "COMMIT")
        #expect(batch.before("INSERT INTO t VALUES (2)") == ["BEGIN"])
        #expect(batch.after() == nil)
        // A PRAGMA or VACUUM runs between batches.
        #expect(batch.before("VACUUM") == ["COMMIT"])
        #expect(!batch.isOpen)
        // The file's own transaction is the file's.
        #expect(batch.before("BEGIN TRANSACTION").isEmpty)
        #expect(batch.before("INSERT INTO t VALUES (3)").isEmpty)
        #expect(batch.after() == nil)
        #expect(batch.before("ROLLBACK TO sp").isEmpty)
        #expect(batch.before("COMMIT").isEmpty)
        #expect(batch.before("INSERT INTO t VALUES (4)") == ["BEGIN"])
        #expect(batch.close() == "COMMIT")
        #expect(batch.close() == nil)
    }

    // MARK: CSV

    @Test func csvMappingSpeaksSQLite() {
        var mapping = CSVMapping(fields: ["id", "name"], columns: ["id", "name"], engine: .sqlite)
        mapping.ignoreDuplicates = true
        #expect(mapping.insertPrefix(table: "people", database: "main") == "INSERT OR IGNORE INTO `main`.`people` (`id`, `name`) VALUES ")
        #expect(mapping.tuple(["1", "O'Neil \\"]) == "('1', 'O''Neil \\')")
        #expect(CSVMapping.guessType(["1", "9000000000"], engine: .sqlite) == "INTEGER")
        #expect(CSVMapping.guessType(["1.5", "2"], engine: .sqlite) == "REAL")
        #expect(CSVMapping.guessType(["2026-11-19"], engine: .sqlite) == "TEXT")
        #expect(CSVMapping.guessType([nil], engine: .sqlite) == "TEXT")
        #expect(CSVMapping.createTable("people", database: "main", fields: [("id", "INTEGER"), ("name", "TEXT")], engine: .sqlite)
            == "CREATE TABLE `main`.`people` (`id` INTEGER, `name` TEXT)")
    }

    // MARK: Dump text

    @Test func dumpParts() {
        #expect(SQLDump.SQLite.header(file: "a.sqlite", version: "SQLite 3.51", date: .now).contains("PRAGMA foreign_keys = OFF;"))
        #expect(SQLDump.SQLite.select(columns: ["a", "b"], table: "t", database: "main", orderBy: ["rowid"])
            == "SELECT quote(`a`) AS `a`, quote(`b`) AS `b` FROM `main`.`t` ORDER BY `rowid`")
        #expect(SQLDump.SQLite.sequence(table: "it's", value: "7")
            == "DELETE FROM sqlite_sequence WHERE name = 'it''s';\nINSERT INTO sqlite_sequence (name, seq) VALUES ('it''s', 7);\n\n")
        var inserts = SQLDump.Inserts(table: "t", columns: [ResultColumn(name: "a"), ResultColumn(name: "b")],
                                      batch: .rows(2), hexBlobs: false, literals: true)
        let text = inserts.append([[.text("1"), .text("'x'")], [.text("X'00'"), .null], [.text("2.5"), .text("'y'")]])
            + inserts.finish()
        #expect(text == "INSERT INTO `t` (`a`, `b`)\nVALUES\n\t(1, 'x'),\n\t(X'00', NULL);\n\n"
            + "INSERT INTO `t` (`a`, `b`)\nVALUES\n\t(2.5, 'y');\n\n")
    }

    @Test func viewsComeAfterTheViewsTheyRead() {
        let order = SQLDump.SQLite.viewOrder([
            "a_report": "CREATE VIEW a_report AS SELECT * FROM totals",
            "totals": "CREATE VIEW totals AS SELECT * FROM \"base\"",
            "base": "CREATE VIEW base AS SELECT 1",
            "totals_old": "CREATE VIEW totals_old AS SELECT 2",
        ])
        #expect(order.firstIndex(of: "base")! < order.firstIndex(of: "totals")!)
        #expect(order.firstIndex(of: "totals")! < order.firstIndex(of: "a_report")!)
    }

    // MARK: Round trip

    private static let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "tools/fixture-sqlite.sql")

    /// Extra rows that quoting could get wrong: quotes, backslashes, line breaks,
    /// reals, a typeless column holding each storage class, and a BLOB.
    private static let awkward = """
    CREATE TABLE awkward (v, t TEXT, r REAL);
    INSERT INTO awkward VALUES (1, 'it''s \\ here', 0.1), ('2', 'line
    break', 1e300), (X'00FF', NULL, -0.0), (3.25, '', 123456789.123456789);
    CREATE VIEW awkward_texts AS SELECT t FROM awkward;
    CREATE VIEW awkward_count AS SELECT count(*) AS n FROM awkward_texts;
    """

    private func newFile(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "quarry-s071-\(name)-\(UUID().uuidString).sqlite")
        try SQLiteFile.create(url)
        return url
    }

    private func open(_ url: URL, readOnly: Bool = false) async throws -> DatabaseClient {
        try await DatabaseClient.connect(ConnectionDetails(transport: .sqlite, file: url.path, readOnly: readOnly))
    }

    private func load(_ sql: String, into client: DatabaseClient) async throws -> ImportSummary {
        let url = FileManager.default.temporaryDirectory.appending(path: "quarry-s071-\(UUID().uuidString).sql")
        try sql.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DumpReader(url: url)
        defer { reader.close() }
        return try await client.importSQL(from: reader, into: nil, onError: { _ in .stop }, progress: { _ in })
    }

    /// The whole file as SQL, generation time left out.
    private func export(_ client: DatabaseClient) async throws -> String {
        let objects = try await client.tablesAndViews(in: "main")
        let url = FileManager.default.temporaryDirectory.appending(path: "quarry-s071-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try DumpFile(url: url, compression: .none)
        try await client.exportSQL(objects.map { ExportItem(object: $0, part: SQLDump.Part()) }, from: "main",
                                   options: SQLDump.Options(), to: file, progress: { _ in })
        try file.close()
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("-- Generation time") && !$0.hasPrefix("-- File:") }.joined(separator: "\n")
    }

    @Test func theFixtureSurvivesExportAndImport() async throws {
        let source = try newFile("source")
        let copy = try newFile("copy")
        defer { [source, copy].forEach { try? FileManager.default.removeItem(at: $0) } }
        let writer = try await open(source)
        let fixture = try String(contentsOf: Self.fixture, encoding: .utf8)
        let loaded = try await load(fixture + "\n" + Self.awkward, into: writer)
        #expect(loaded.failures.isEmpty, "\(loaded.failures.map(\.text))")
        await writer.close()

        // Export on a read-only connection, as the sheet does.
        let reader = try await open(source, readOnly: true)
        let first = try await export(reader)
        await reader.close()
        #expect(first.contains("CREATE TRIGGER products_stock_check"))
        #expect(first.contains("CREATE INDEX orders_customer"))
        #expect(first.contains("INSERT INTO sqlite_sequence (name, seq) VALUES ('customers', 6);"))
        #expect(!first.contains("LOCK TABLES") && !first.contains("SET NAMES"))
        #expect(first.range(of: "CREATE VIEW awkward_texts")!.lowerBound < first.range(of: "CREATE VIEW awkward_count")!.lowerBound)

        let target = try await open(copy)
        let summary = try await load(first, into: target)
        #expect(summary.failures.isEmpty, "\(summary.failures.map(\.text))")
        let second = try await export(target)
        #expect(second == first)
        let types = try await target.run("SELECT typeof(v), typeof(r) FROM awkward ORDER BY rowid").rows
            .map { $0.compactMap(\.plainText).joined(separator: "/") }
        #expect(types == ["integer/real", "text/real", "blob/real", "real/real"])
        let text = try await target.run("SELECT t FROM awkward WHERE rowid = 1").rows.first?.first?.plainText
        #expect(text == "it's \\ here")
        // The trigger came back and still works.
        let refused = await target.execute("UPDATE products SET stock = -1 WHERE id = 1")
        #expect(refused?.message == "stock can't go below zero")
        await target.close()
    }

    // MARK: Filters

    @Test func filtersQuoteForSQLite() {
        #expect(RowFilter(column: "name", op: .equals, value: "it's").whereClause(engine: .sqlite) == "`name` = 'it''s'")
        #expect(RowFilter(column: "name", op: .contains, value: "50%\\").whereClause(engine: .sqlite)
            == "`name` LIKE '%50\\%\\\\%' ESCAPE '\\'")
        #expect(RowFilter(column: "name", op: .contains, value: "50%").whereClause == "`name` LIKE '%50\\\\%%'")
        var tree = FilterTree(RowFilter(column: "a", op: .isIn, value: "x, o'k"))
        tree.add(RowFilter(column: "b", op: .startsWith, value: "a_b"), below: tree.rules[0].id)
        #expect(tree.whereClause(engine: .sqlite) == "`a` IN ('x', 'o''k') AND `b` LIKE 'a\\_b%' ESCAPE '\\'")
    }

    /// Copy as SQL INSERT from a SQLite file pastes back into one with the same values.
    @Test func copiedInsertReadsBackInAFile() async throws {
        let url = try newFile("copy")
        defer { try? FileManager.default.removeItem(at: url) }
        let client = try await open(url)
        _ = try await client.run("CREATE TABLE t (name TEXT)")
        let values = ["it's", "C:\\dir\\", "line\nbreak", "\\'"]
        let rows = values.map { [CellValue.text($0)] }
        _ = try await client.run(RowCopy.insertStatement(table: "t", columns: ["name"], rows: rows, engine: .sqlite))
        let back = try await client.run("SELECT name FROM t ORDER BY rowid").rows.compactMap { $0.first?.plainText }
        #expect(back == values)
    }

    @Test func filtersFindAwkwardTextInAFile() async throws {
        let url = try newFile("filters")
        defer { try? FileManager.default.removeItem(at: url) }
        let client = try await open(url)
        _ = try await client.run("CREATE TABLE t (name TEXT)")
        _ = try await client.run("INSERT INTO t VALUES ('it''s'), ('50% off'), ('500 off'), ('C:\\dir'), ('a_b'), ('axb')")
        func matches(_ op: RowFilter.Operator, _ value: String) async throws -> [String] {
            let condition = RowFilter(column: "name", op: op, value: value).whereClause(engine: .sqlite)!
            return try await client.run("SELECT name FROM t WHERE \(condition) ORDER BY rowid").rows.compactMap { $0.first?.plainText }
        }
        #expect(try await matches(.equals, "it's") == ["it's"])
        #expect(try await matches(.contains, "0%") == ["50% off"])
        #expect(try await matches(.contains, "C:\\") == ["C:\\dir"])
        #expect(try await matches(.startsWith, "a_") == ["a_b"])
        #expect(try await matches(.isIn, "it's, axb") == ["it's", "axb"])
        await client.close()
    }

    @Test func aDelimiterLineStopsTheImport() async throws {
        let url = try newFile("delimiter")
        defer { try? FileManager.default.removeItem(at: url) }
        let client = try await open(url)
        await #expect(throws: DatabaseError.self) {
            _ = try await load("CREATE TABLE t (a);\nDELIMITER ;;\nINSERT INTO t VALUES (1);;\n", into: client)
        }
        // What ran before the line stays.
        let tables = try await client.tablesAndViews(in: "main").map(\.name)
        #expect(tables == ["t"])
        await client.close()
    }
}
