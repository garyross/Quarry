import Foundation
import Testing
@testable import QuarryKit

@Suite("SQL export (S-041)")
struct SQLDumpTests {
    let text = ResultColumn(name: "name", typeName: "varString")
    let number = ResultColumn(name: "id", typeName: "long", isNumeric: true)
    let blob = ResultColumn(name: "data", typeName: "blob", isBinary: true)
    let bit = ResultColumn(name: "flags", typeName: "bit", isNumeric: true, bitWidth: 4)

    @Test func escapesStrings() {
        #expect(SQLDump.literal(.text("O'Brien"), column: text, hexBlobs: true) == "'O\\'Brien'")
        #expect(SQLDump.literal(.text("a\\b\nc\0"), column: text, hexBlobs: true) == "'a\\\\b\\nc\\0'")
        #expect(SQLDump.literal(.text("Zoë 🙂"), column: text, hexBlobs: true) == "'Zoë 🙂'")
    }

    @Test func writesNullNumbersAndBits() {
        #expect(SQLDump.literal(.null, column: text, hexBlobs: true) == "NULL")
        #expect(SQLDump.literal(.null, column: blob, hexBlobs: true) == "NULL")
        #expect(SQLDump.literal(.text("-12.5e3"), column: number, hexBlobs: true) == "-12.5e3")
        // A numeric column holding something odd is quoted, never written bare.
        #expect(SQLDump.literal(.text("1; DROP"), column: number, hexBlobs: true) == "'1; DROP'")
        #expect(SQLDump.literal(.binary(Data([0b0101])), column: bit, hexBlobs: true) == "b'0101'")
    }

    @Test func writesBinaryAsHex() {
        #expect(SQLDump.literal(.binary(Data([0x00, 0xFF, 0x10])), column: blob, hexBlobs: false) == "X'00FF10'")
        #expect(SQLDump.literal(.binary(Data()), column: blob, hexBlobs: true) == "''")
        // Readable bytes in a binary column: hex with the option, quoted text without.
        #expect(SQLDump.literal(.text("ab"), column: blob, hexBlobs: true) == "X'6162'")
        #expect(SQLDump.literal(.text("ab"), column: blob, hexBlobs: false) == "'ab'")
    }

    @Test func batchesByRows() {
        var inserts = SQLDump.Inserts(table: "t", columns: [number, text], batch: .rows(2), hexBlobs: true)
        let rows: [[CellValue]] = (1...5).map { [.text("\($0)"), .text("r\($0)")] }
        let out = inserts.append(Array(rows[0..<3])) + inserts.append(Array(rows[3...])) + inserts.finish()
        #expect(out.components(separatedBy: "INSERT INTO `t` (`id`, `name`)\nVALUES\n").count - 1 == 3)
        #expect(out.hasPrefix("INSERT INTO `t` (`id`, `name`)\nVALUES\n\t(1, 'r1'),\n\t(2, 'r2');\n\nINSERT"))
        #expect(out.hasSuffix("\t(5, 'r5');\n\n"))
    }

    @Test func batchesBySize() {
        var inserts = SQLDump.Inserts(table: "t", columns: [text], batch: .kilobytes(1), hexBlobs: true)
        let value = String(repeating: "x", count: 300)
        let out = inserts.append(Array(repeating: [.text(value)], count: 10)) + inserts.finish()
        let statements = out.components(separatedBy: ";\n\n").filter { !$0.isEmpty }
        #expect(statements.count == 4)
        #expect(statements.allSatisfy { $0.utf8.count <= 1024 })
        // A row bigger than the limit still goes out, alone.
        var big = SQLDump.Inserts(table: "t", columns: [text], batch: .kilobytes(1), hexBlobs: true)
        let huge = big.append([[.text(String(repeating: "y", count: 2000))], [.text("z")]]) + big.finish()
        #expect(huge.components(separatedBy: "INSERT INTO").count - 1 == 2)
    }

    @Test func noRowsWritesNothing() {
        var inserts = SQLDump.Inserts(table: "t", columns: [text], batch: .standard, hexBlobs: true)
        #expect(inserts.append([]) + inserts.finish() == "")
    }

    @Test func structureHonorsTheOptions() {
        let create = "CREATE TABLE `t` (\n  `id` int NOT NULL AUTO_INCREMENT\n) ENGINE=InnoDB AUTO_INCREMENT=42 DEFAULT CHARSET=utf8mb4"
        let table = DBObject(name: "t", kind: .table)
        let all = SQLDump.structure(table, createStatement: create, part: .init(), options: .init())
        #expect(all.hasPrefix("DROP TABLE IF EXISTS `t`;\n\nCREATE TABLE"))
        #expect(all.contains("AUTO_INCREMENT=42"))
        let bare = SQLDump.structure(table, createStatement: create + ";", part: .init(drop: false),
                                     options: .init(autoIncrement: false))
        #expect(bare.hasPrefix("CREATE TABLE"))
        #expect(!bare.contains("AUTO_INCREMENT=42") && bare.contains("NOT NULL AUTO_INCREMENT"))
        #expect(bare.hasSuffix("utf8mb4;\n\n"))
        let view = SQLDump.structure(DBObject(name: "v", kind: .view), createStatement: "CREATE VIEW `v` AS select 1",
                                     part: .init(structure: false), options: .init())
        #expect(view == "DROP VIEW IF EXISTS `v`;\n\n")
    }

    @Test func routinesAndTriggersUseDelimiters() {
        let routine = SQLDump.routine(DBObject(name: "p", kind: .procedure), createStatement: "CREATE PROCEDURE `p`() BEGIN SELECT 1; END",
                                      part: .init())
        #expect(routine == "DELIMITER ;;\nDROP PROCEDURE IF EXISTS `p`;;\nCREATE PROCEDURE `p`() BEGIN SELECT 1; END;;\nDELIMITER ;\n\n")
        #expect(SQLDump.triggers([]) == "")
        let split = StatementSplitter.split(routine + SQLDump.triggers(["CREATE TRIGGER x BEFORE INSERT ON t FOR EACH ROW SET @a = 1;"]))
        #expect(split.map(\.text).filter { !$0.isEmpty }.count == 3)
    }

    @Test func viewsFollowTheViewsTheyRead() {
        let order = SQLDump.viewOrder([
            "a_totals": "CREATE VIEW `a_totals` AS select * from `z_base`",
            "m_other": "CREATE VIEW `m_other` AS select 1",
            "z_base": "CREATE VIEW `z_base` AS select * from `orders`",
        ])
        #expect(order == ["z_base", "a_totals", "m_other"])
        // A loop can't hang it.
        #expect(Set(SQLDump.viewOrder(["a": "`b`", "b": "`a`"])) == ["a", "b"])
    }

    @Test func unqualifiesTheDatabase() {
        #expect(SQLDump.unqualified("select `quarry_demo`.`orders`.`id` from `quarry_demo`.`orders`", database: "quarry_demo")
            == "select `orders`.`id` from `orders`")
    }

    @Test func gzipFilesDecompress() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "quarry-dump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "dump.sql.gz")
        let file = try DumpFile(url: url, compression: .gzip)
        let line = "INSERT INTO `t` VALUES (1, 'Zoë');\n"
        for _ in 0..<20_000 { try file.write(line) }
        try file.close()
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size > 0 && size < file.bytesWritten / 10)
        let gunzip = Process()
        gunzip.executableURL = URL(filePath: "/usr/bin/gunzip")
        gunzip.arguments = ["-c", url.path]
        let pipe = Pipe()
        gunzip.standardOutput = pipe
        try gunzip.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        gunzip.waitUntilExit()
        #expect(gunzip.terminationStatus == 0)
        #expect(data.count == file.bytesWritten)
        #expect(String(decoding: data.prefix(line.utf8.count), as: UTF8.self) == line)
    }

    @Test func discardRemovesTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "quarry-discard-\(UUID().uuidString).sql")
        let file = try DumpFile(url: url, compression: .none)
        try file.write("SELECT 1;\n")
        file.discard()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func progressCountsTheCurrentTable() {
        #expect(ExportProgress(text: "", done: 1, total: 4, rows: 50, tableRows: 100).fraction == 0.375)
        #expect(ExportProgress(text: "", done: 0, total: 0).fraction == 0)
    }
}
