import Testing
@testable import QuarryKit

struct ClipboardTextTests {
    @Test func spreadsheetCellsAreTabSeparated() {
        #expect(ClipboardText.guess("Name\tAge\nAnn\t31\n") == .csv(separator: "\t"))
        #expect(ClipboardText.guess("\n\nAnn\t31") == .csv(separator: "\t"))
    }

    @Test func statementsAndCommentsAreSQL() {
        #expect(ClipboardText.guess("INSERT INTO t VALUES (1, 'a,b');") == .sql)
        #expect(ClipboardText.guess("  select 1") == .sql)
        #expect(ClipboardText.guess("COMMIT;") == .sql)
        #expect(ClipboardText.guess("-- dump\nCREATE TABLE t (id INT);") == .sql)
        #expect(ClipboardText.guess("/*!40101 SET NAMES utf8 */;") == .sql)
        #expect(ClipboardText.guess("DROP") == .sql)
    }

    @Test func headerRowsThatStartWithAKeywordStayCSV() {
        #expect(ClipboardText.guess("Update,Price\n1,2") == .csv(separator: ","))
        #expect(ClipboardText.guess("Select;Count") == .csv(separator: ";"))
        #expect(ClipboardText.guess("Settings\tValue") == .csv(separator: "\t"))
    }

    @Test func theMostFrequentSeparatorWins() {
        #expect(ClipboardText.guess("a|b|c,d") == .csv(separator: "|"))
        #expect(ClipboardText.guess("just words") == .csv(separator: ","))
        #expect(ClipboardText.guess("") == .csv(separator: ","))
    }

    @Test func previewCutsLinesAndCountsThem() {
        #expect(ClipboardText.preview("a\nb\nc\n", lines: 2) == "a\nb\n…")
        #expect(ClipboardText.preview("a\nb\n", lines: 2) == "a\nb")
        #expect(ClipboardText.preview(String(repeating: "x", count: 5), width: 3) == "xxx…")
        #expect(ClipboardText.summary("a\nb\n") == "2 lines, 4 bytes")
    }

    @Test func tabSeparatedPreviewLinesUpInColumns() {
        #expect(ClipboardText.preview("Name\tCity\nZoë Martin\tLyon\n") == "Name        City\nZoë Martin  Lyon")
        #expect(ClipboardText.preview("abcdef\tx", cell: 4) == "abc…  x")
    }
}
