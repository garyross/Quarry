import Foundation
import Testing
@testable import QuarryKit

@Suite("CSV, JSON and XML export (S-042)")
struct DataExportTests {
    let name = ResultColumn(name: "name", typeName: "varString")
    let id = ResultColumn(name: "id", typeName: "long", isNumeric: true)
    let price = ResultColumn(name: "price", typeName: "newdecimal", isNumeric: true)
    let bit = ResultColumn(name: "flags", typeName: "bit", isNumeric: true, bitWidth: 4)
    let blob = ResultColumn(name: "data", typeName: "blob", isBinary: true)

    @Test func csvQuotesSeparatorsQuotesAndNewlines() {
        let options = DataExport.CSVOptions()
        #expect(DataExport.csvField(.text("a,b"), column: name, options: options) == "\"a,b\"")
        #expect(DataExport.csvField(.text("say \"hi\""), column: name, options: options) == "\"say \"\"hi\"\"\"")
        #expect(DataExport.csvField(.text("line1\nline2"), column: name, options: options) == "\"line1\nline2\"")
        #expect(DataExport.csvField(.text(""), column: name, options: options) == "\"\"")
        #expect(DataExport.csvField(.null, column: name, options: options) == "NULL")
        #expect(DataExport.csvField(.text("42"), column: id, options: options) == "42")
        // A number in a text column stays quoted, so "007" keeps its zeros.
        #expect(DataExport.csvField(.text("007"), column: name, options: options) == "\"007\"")
        #expect(DataExport.csvField(.binary(Data([0b0101])), column: bit, options: options) == "5")
        #expect(DataExport.csvField(.binary(Data([0xFF, 0x00])), column: blob, options: options) == "\"0xFF00\"")
    }

    @Test func csvWithBackslashEscapeAndNoEnclosure() {
        let backslash = DataExport.CSVOptions(escape: "\\")
        #expect(DataExport.csvField(.text("a\"b\\c"), column: name, options: backslash) == "\"a\\\"b\\\\c\"")
        let bare = DataExport.CSVOptions(fieldSeparator: "\t", enclosure: "", escape: "\\", nullText: "\\N")
        #expect(DataExport.csvField(.text("a\tb\nc"), column: name, options: bare) == "a\\\tb\\\nc")
        #expect(DataExport.csvField(.null, column: name, options: bare) == "\\N")
        #expect(DataExport.csvRow([.text("1"), .text("x y")], columns: [id, name], options: bare) == "1\tx y\n")
    }

    @Test func csvFileHasAHeaderPerTable() {
        var writer = DataExport.Writer(format: .csv, shape: .tables(database: "d"),
                                       csv: .init(lineEnd: "\r\n"))
        var out = writer.start() + writer.begin("a", columns: [id, name])
        out += writer.append([[.text("1"), .text("x")]]) + writer.end()
        out += writer.begin("b", columns: [id]) + writer.append([[.text("2")]]) + writer.end() + writer.finish()
        #expect(out == "\"id\",\"name\"\r\n1,\"x\"\r\n\r\n\"id\"\r\n2\r\n")
        var noHeader = DataExport.Writer(format: .csv, shape: .rows(statement: ""), csv: .init(header: false))
        #expect(noHeader.begin("r", columns: [id]) + noHeader.append([[.text("3")]]) == "3\n")
    }

    @Test func jsonKeepsNumbersAndNull() {
        #expect(DataExport.jsonValue(.text("12"), column: id) == "12")
        #expect(DataExport.jsonValue(.text("-0.50"), column: price) == "-0.50")
        #expect(DataExport.jsonValue(.null, column: id) == "null")
        #expect(DataExport.jsonValue(.text("12"), column: name) == "\"12\"")
        // Not JSON's number grammar: quoted, so the file still parses.
        #expect(DataExport.jsonValue(.text(".5"), column: price) == "\".5\"")
        #expect(DataExport.jsonValue(.text("NaN"), column: price) == "\"NaN\"")
        #expect(DataExport.jsonValue(.binary(Data([0b1001])), column: bit) == "9")
        #expect(DataExport.jsonString("a\"b\\c\nd\u{1}") == "\"a\\\"b\\\\c\\nd\\u0001\"")
    }

    @Test func jsonFilesParse() throws {
        var tables = DataExport.Writer(format: .json, shape: .tables(database: "d"))
        var out = tables.start() + tables.begin("a", columns: [id, name])
        out += tables.append([[.text("1"), .text("x\n\"y\"")], [.text("2"), .null]]) + tables.end()
        out += tables.begin("empty", columns: [id]) + tables.end() + tables.finish()
        let object = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: [[String: Any]]]
        #expect(object?["a"]?.count == 2)
        #expect(object?["a"]?[0]["id"] as? Int == 1)
        #expect(object?["a"]?[0]["name"] as? String == "x\n\"y\"")
        #expect(object?["a"]?[1]["name"] is NSNull)
        #expect(object?["empty"]?.isEmpty == true)

        var rows = DataExport.Writer(format: .json, shape: .rows(statement: "SELECT 1"))
        let text = rows.start() + rows.begin("r", columns: [price]) + rows.append([[.text("1.5")]]) + rows.end() + rows.finish()
        let array = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]
        #expect(array?.first?["price"] as? Double == 1.5)
    }

    @Test func xmlEscapesAndMarksNull() throws {
        var writer = DataExport.Writer(format: .xml, shape: .tables(database: "shop"))
        var out = writer.start() + writer.begin("t<1>", columns: [id, name])
        out += writer.append([[.text("1"), .text("A & B <c> \u{1}")], [.text("2"), .null]]) + writer.end() + writer.finish()
        #expect(out.contains("<table_data name=\"t&lt;1&gt;\">"))
        #expect(out.contains("<field name=\"name\">A &amp; B &lt;c&gt; \u{FFFD}</field>"))
        #expect(out.contains("<field name=\"name\" xsi:nil=\"true\" />"))
        let parser = XMLParser(data: Data(out.utf8))
        #expect(parser.parse(), "\(parser.parserError.map { "\($0)" } ?? "")")

        var result = DataExport.Writer(format: .xml, shape: .rows(statement: "SELECT \"x\" < 2"))
        let text = result.start() + result.begin("r", columns: [id]) + result.append([[.text("1")]]) + result.end() + result.finish()
        #expect(text.contains("<resultset statement=\"SELECT &quot;x&quot; &lt; 2\""))
        #expect(XMLParser(data: Data(text.utf8)).parse())
    }
}
