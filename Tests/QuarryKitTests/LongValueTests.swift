import Foundation
import Testing
@testable import QuarryKit

struct LongValueTests {
    @Test func prettyPrintKeepsKeyOrderAndNumbers() {
        let compact = #"{"color":"white","volume_ml":350,"sizes":[1.50,2e3],"empty":{},"none":[],"note":"a, b: {c}"}"#
        let pretty = JSONText.pretty(compact)
        #expect(pretty == """
        {
          "color": "white",
          "volume_ml": 350,
          "sizes": [
            1.50,
            2e3
          ],
          "empty": {},
          "none": [],
          "note": "a, b: {c}"
        }
        """)
        #expect(JSONText.check(pretty) == nil)
        #expect(JSONText.compact(pretty) == compact)
        #expect(JSONText.pretty(pretty) == pretty)
    }

    @Test func escapesInStringsSurvive() {
        let text = #"["quote \" and \\ and é", "tab\there"]"#
        #expect(JSONText.check(text) == nil)
        #expect(JSONText.compact(JSONText.pretty(text)) == #"["quote \" and \\ and é","tab\there"]"#)
    }

    @Test func invalidJSONIsFlaggedWithWhere() {
        let problem = JSONText.check("{\n  \"a\": 1,\n  \n}")
        #expect(problem?.line == 4 && problem?.column == 1)
        #expect(problem?.message == "expected a key in quotes")
        #expect(JSONText.check("[1, 2") != nil)
        #expect(JSONText.check("{\"a\" 1}")?.message == "expected “:” after the key")
        #expect(JSONText.check("[01]") != nil)
        #expect(JSONText.check("\"open") != nil)
        #expect(JSONText.check("{} x")?.message == "unexpected text after the value")
        #expect(JSONText.check("") != nil)
        #expect(JSONText.check("  42 ") == nil)
        // Invalid text is never reformatted.
        #expect(JSONText.pretty("{\"a\":") == "{\"a\":")
    }

    @Test func compactIsDetected() {
        #expect(JSONText.isCompact(#"{"a":1}"#))
        #expect(!JSONText.isCompact(#"{"a": 1}"#))
        #expect(!JSONText.isCompact("nope"))
    }

    @Test func whichValuesOpenTheFieldEditor() {
        #expect(!LongValue.opensFieldEditor(.text("short"), fieldType: "text"))
        #expect(LongValue.opensFieldEditor(.text("short"), fieldType: "json"))
        #expect(LongValue.opensFieldEditor(.null, fieldType: "longblob"))
        #expect(!LongValue.opensFieldEditor(.text("short"), fieldType: "varchar"))
        #expect(LongValue.opensFieldEditor(.text("two\nlines"), fieldType: "varchar"))
        #expect(LongValue.opensFieldEditor(.text(String(repeating: "x", count: 201)), fieldType: "varchar"))
        #expect(LongValue.opensFieldEditor(.text("[1,2]"), fieldType: nil))
        #expect(!LongValue.opensFieldEditor(.text("[draft]"), fieldType: nil))
        #expect(LongValue.opensFieldEditor(.binary(Data([0])), fieldType: "varbinary"))
        #expect(!LongValue.opensFieldEditor(.null, fieldType: "int"))
        #expect(LongValue.isJSON(.null, fieldType: "JSON"))
        #expect(LongValue.isJSON(.text(#"{"a":1}"#), fieldType: "longtext"))
        #expect(!LongValue.isJSON(.text("A mug."), fieldType: "text"))
    }

    @Test func hexDumpLines() {
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x41])
        let lines = HexDump.format(data).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == "00000000  89 50 4E 47 0D 0A 1A 0A  00 00 00 0D 49 48 44 52  |.PNG........IHDR|")
        #expect(lines[1] == "00000010  41" + String(repeating: " ", count: 48) + "|A|")
        #expect(HexDump.format(Data(count: 40), limit: 16).hasSuffix("… 24 bytes more"))
        #expect(HexDump.format(Data()) == "")
    }
}
