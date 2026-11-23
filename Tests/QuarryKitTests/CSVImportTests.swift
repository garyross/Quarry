import Foundation
import Testing
@testable import QuarryKit

struct CSVStreamParserTests {
    /// Feeds `text` in pieces of `size` bytes, so every token is split somewhere.
    private func parse(_ text: String, _ options: DataExport.CSVOptions = .init(), size: Int = .max,
                       encoding: String.Encoding = .utf8) throws -> [CSVRow] {
        var parser = CSVStreamParser(options: options, encoding: encoding)
        let bytes = encoding == .utf8 ? Array(text.utf8) : [UInt8](text.data(using: encoding)!)
        var out: [CSVRow] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + max(1, min(size, bytes.count)))
            out += try parser.append(bytes[offset..<end])
            offset = end
        }
        return out + (try parser.finish())
    }

    @Test func commasQuotesAndALastLineWithoutAnEnd() throws {
        let rows = try parse("id,name\n1,\"Zoë, Ann\"\n2,Bob")
        #expect(rows == [["id", "name"], ["1", "Zoë, Ann"], ["2", "Bob"]])
    }

    @Test func doubledQuotesAndLineBreaksInsideQuotes() throws {
        let rows = try parse("1,\"say \"\"hi\"\"\nthere\"\n")
        #expect(rows == [["1", "say \"hi\"\nthere"]])
    }

    @Test func backslashEscapes() throws {
        let options = DataExport.CSVOptions(escape: "\\")
        let rows = try parse("1,\"a \\\"b\\\" c\",x\\,y\n", options)
        #expect(rows == [["1", "a \"b\" c", "x,y"]])
    }

    @Test func nullIsUnquotedNullOrBackslashN() throws {
        let rows = try parse("NULL,\"NULL\",\\N,\n")
        #expect(rows == [[nil, "NULL", nil, ""]])
        let custom = try parse("-,NULL\n", DataExport.CSVOptions(nullText: "-"))
        #expect(custom == [[nil, "NULL"]])
    }

    @Test func tabsSemicolonsAndWindowsLineEnds() throws {
        #expect(try parse("a\tb\r\nc\td\r\n", DataExport.CSVOptions(fieldSeparator: "\t")) == [["a", "b"], ["c", "d"]])
        #expect(try parse("a;b\r\nc;d", DataExport.CSVOptions(fieldSeparator: ";", lineEnd: "\r\n")) == [["a", "b"], ["c", "d"]])
        #expect(try parse("a,b\rc,d\r", DataExport.CSVOptions(lineEnd: "\r")) == [["a", "b"], ["c", "d"]])
    }

    @Test func blankLinesAreSkipped() throws {
        #expect(try parse("a\n\nb\n\n") == [["a"], ["b"]])
    }

    @Test func noEnclosure() throws {
        #expect(try parse("\"a\",b\n", DataExport.CSVOptions(enclosure: "")) == [["\"a\"", "b"]])
    }

    @Test func everySplitPointReadsTheSame() throws {
        let text = "id;\"na;me\"\r\n1;\"Zoë \"\"Z\"\"\r\nnext\"\r\n2;\\N\r\n"
        let options = DataExport.CSVOptions(fieldSeparator: ";", lineEnd: "\r\n")
        let whole = try parse(text, options)
        #expect(whole == [["id", "na;me"], ["1", "Zoë \"Z\"\r\nnext"], ["2", nil]])
        for size in 1...8 { #expect(try parse(text, options, size: size) == whole) }
    }

    @Test func latin1AndABadEncoding() throws {
        #expect(try parse("café,1\n", encoding: .isoLatin1) == [["café", "1"]])
        var parser = CSVStreamParser(options: .init())
        #expect(throws: DatabaseError.self) { _ = try parser.append([0x63, 0xE9, 0x0A]) }
    }
}

struct CSVMappingTests {
    @Test func fileOrderAndReversed() {
        #expect(CSVMapping.align(.fileOrder, columns: ["a", "b"], fields: ["x", "y", "z"]) == [0, 1, nil])
        #expect(CSVMapping.align(.reversed, columns: ["a", "b", "c"], fields: ["x", "y"]) == [2, 1])
        #expect(CSVMapping.align(.custom, columns: ["a"], fields: ["x"]) == [nil])
    }

    @Test func matchingNamesIgnoresCaseAndSeparators() {
        let sources = CSVMapping.align(.matchingNames, columns: ["Name", "Created At", "id"],
                                       fields: ["id", "name", "created_at", "email"])
        #expect(sources == [2, 0, 1, nil])
    }

    @Test func columnNamesFromTheHeaderOrNumbered() {
        #expect(CSVMapping.columnNames(header: ["id", nil, " "], count: 4) == ["id", "Column 2", "Column 3", "Column 4"])
        #expect(CSVMapping.columnNames(header: nil, count: 2) == ["Column 1", "Column 2"])
    }

    @Test func insertReplaceAndIgnore() {
        var mapping = CSVMapping(fields: ["id", "name", "note"], columns: ["a", "b"], engine: .mysql)
        #expect(mapping.insertPrefix(table: "t", database: "db") == "INSERT INTO `db`.`t` (`id`, `name`) VALUES ")
        #expect(mapping.tuple(["1", "O'Brien"]) == "('1', 'O\\'Brien')" || mapping.tuple(["1", "O'Brien"]) == "('1', 'O''Brien')")
        #expect(mapping.tuple(["1"]) == "('1', NULL)")
        #expect(mapping.tuple(["1", nil]) == "('1', NULL)")
        mapping.ignoreDuplicates = true
        #expect(mapping.insertPrefix(table: "t", database: "db").hasPrefix("INSERT IGNORE INTO "))
        mapping.method = .replace
        #expect(mapping.insertPrefix(table: "t", database: "db").hasPrefix("REPLACE INTO "))
    }

    @Test func updateMatchesOnTheCheckedFields() {
        var mapping = CSVMapping(fields: ["id", "name", "note"], columns: ["a", "b", "c"], engine: .mysql)
        mapping.method = .update
        #expect(mapping.problem?.hasPrefix("Check Match") == true)
        mapping.matchFields = ["id", "name", "note"]
        #expect(mapping.problem?.hasPrefix("Import at least one field") == true)
        mapping.matchFields = ["id", "note"]
        #expect(mapping.problem == nil)
        #expect(mapping.update(["7", "Ann", nil], table: "t", database: "db")
                == "UPDATE `db`.`t` SET `name` = 'Ann' WHERE `id` = '7' AND `note` IS NULL")
    }

    @Test func nothingMapped() {
        let mapping = CSVMapping(fields: ["id"], columns: ["a"], alignment: .custom, engine: .mysql)
        #expect(mapping.problem == "Choose a column for at least one field.")
    }

    @Test func guessedTypes() {
        #expect(CSVMapping.guessType(["1", "-20", nil, ""], engine: .mysql) == "INT")
        #expect(CSVMapping.guessType(["1", "9000000000"], engine: .mysql) == "BIGINT")
        #expect(CSVMapping.guessType(["1.5", "-12.25", "3"], engine: .mysql) == "DECIMAL(4,2)")
        #expect(CSVMapping.guessType(["2026-11-19"], engine: .mysql) == "DATE")
        #expect(CSVMapping.guessType(["2026-11-19 10:00:00", "2026-11-19T10:00"], engine: .mysql) == "DATETIME")
        #expect(CSVMapping.guessType(["abc", "1"], engine: .mysql) == "VARCHAR(255)")
        #expect(CSVMapping.guessType([String(repeating: "x", count: 300)], engine: .mysql) == "TEXT")
        #expect(CSVMapping.guessType([nil], engine: .mysql) == "VARCHAR(255)")
    }

    @Test func createTable() {
        #expect(CSVMapping.createTable("people", database: "db", fields: [("id", "INT"), ("name", "VARCHAR(255)")], engine: .mysql)
                == "CREATE TABLE `db`.`people` (`id` INT NULL, `name` VARCHAR(255) NULL)")
    }
}
