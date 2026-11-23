import Foundation
import Testing
@testable import QuarryKit

struct SQLStreamSplitterTests {
    /// Feeds `sql` in pieces of `size` bytes and returns the statements as text.
    private func split(_ sql: String, size: Int = .max) -> [String] {
        var splitter = SQLStreamSplitter(engine: .mysql)
        let bytes = Array(sql.utf8)
        var out: [[UInt8]] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + max(1, min(size, bytes.count)))
            out += splitter.append(bytes[offset..<end])
            offset = end
        }
        out += splitter.finish()
        return out.map { String(decoding: $0, as: UTF8.self) }
    }

    private let dump = """
        -- Quarry SQL dump
        /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
        SET NAMES utf8mb4;

        CREATE TABLE `a;b` (
          `id` int NOT NULL, -- the key; really
          `note` varchar(20) DEFAULT 'it''s; fine' /* a comment; here */
        );
        INSERT INTO `a;b` VALUES (1,'back\\'slash;'),(2,"dou""ble;"),(3,'Zoë 😀');
        # a hash comment;
        DELIMITER ;;
        CREATE TRIGGER t BEFORE INSERT ON `a;b` FOR EACH ROW BEGIN
          SET NEW.note = 'x;y';
        END ;;
        delimiter ;
        /* only a comment; */
        SELECT 1
        """

    private let expected = [
        "/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */",
        "SET NAMES utf8mb4",
        "CREATE TABLE `a;b` (\n  `id` int NOT NULL, -- the key; really\n  `note` varchar(20) DEFAULT 'it''s; fine' /* a comment; here */\n)",
        "INSERT INTO `a;b` VALUES (1,'back\\'slash;'),(2,\"dou\"\"ble;\"),(3,'Zoë 😀')",
        "CREATE TRIGGER t BEFORE INSERT ON `a;b` FOR EACH ROW BEGIN\n  SET NEW.note = 'x;y';\nEND",
        "SELECT 1",
    ]

    @Test func splitsADumpWithDelimiterBlocks() {
        #expect(split(dump) == expected)
    }

    /// Every buffer size gives the same statements: quotes, comments, the
    /// DELIMITER line, `;;` and multi-byte characters cut anywhere are waited for.
    @Test(arguments: [1, 2, 3, 5, 7, 16, 64])
    func statementsSplitAcrossBuffers(size: Int) {
        #expect(split(dump, size: size) == expected)
    }

    @Test func commentsOnlyAreDropped() {
        #expect(split("-- nothing\n/* nothing */;\n# nothing;\n;;\n").isEmpty)
        #expect(split("--\nSELECT 2;") == ["SELECT 2"])
    }

    @Test func doubleDashNeedsASpaceToBeAComment() {
        #expect(split("SELECT 3--1;SELECT 4") == ["SELECT 3--1", "SELECT 4"])
    }

    @Test func aDelimiterWordInsideAStatementIsNotACommand() {
        #expect(split("SELECT 'DELIMITER //';\nSELECT 5;") == ["SELECT 'DELIMITER //'", "SELECT 5"])
        #expect(split("DELIMITERS;") == ["DELIMITERS"])
    }

    @Test func aDelimiterCommandAtTheEndOfTheFile() {
        var splitter = SQLStreamSplitter(engine: .mysql)
        #expect(splitter.append(Array("SELECT 1;\nDELIMITER $$".utf8)) == [Array("SELECT 1".utf8)])
        #expect(splitter.finish().isEmpty)
        #expect(splitter.currentDelimiter == "$$")
    }

    @Test func anUnterminatedQuoteEndsTheFileAsOneStatement() {
        #expect(split("SELECT 'open;\nSELECT 6;") == ["SELECT 'open;\nSELECT 6;"])
    }

    @Test func gzipFilesReadBackWhole() throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "quarry-reader-\(UUID().uuidString).sql.gz")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try DumpFile(url: url, compression: .gzip)
        let line = "INSERT INTO t VALUES (1,'Zoë');\n"
        let text = String(repeating: line, count: 60_000)
        try file.write(text)
        try file.close()

        let reader = try DumpReader(url: url)
        #expect(reader.isCompressed)
        var bytes: [UInt8] = []
        var splitter = SQLStreamSplitter(engine: .mysql)
        var statements = 0
        while let chunk = try reader.read() {
            bytes += chunk
            statements += splitter.append(chunk).count
        }
        statements += splitter.finish().count
        #expect(String(decoding: bytes, as: UTF8.self) == text)
        #expect(statements == 60_000)
        #expect(reader.bytesRead == reader.totalBytes)
    }

    @Test func plainFilesReadInChunks() throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "quarry-reader-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = String(repeating: "SELECT 1;\n", count: 300_000)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let reader = try DumpReader(url: url)
        #expect(!reader.isCompressed)
        var chunks = 0
        var total = 0
        while let chunk = try reader.read() {
            chunks += 1
            total += chunk.count
        }
        #expect(chunks == 3 && total == text.utf8.count && reader.bytesRead == total)
    }

    @Test func progressText() {
        let progress = ImportProgress(statements: 1_200, errors: 0, bytesRead: 1_500_000, totalBytes: 3_000_000)
        #expect(progress.fraction == 0.5)
        #expect(progress.text.hasSuffix("· 1,200 statements"))
    }
}
