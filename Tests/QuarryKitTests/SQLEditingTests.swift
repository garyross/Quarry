import Foundation
import Testing
@testable import QuarryKit

/// S-032: each editor helper on a sample buffer, and Undo (the inverse edit) restores it.
struct SQLEditingTests {
    private func range(_ text: String, of part: String) -> NSRange {
        (text as NSString).range(of: part)
    }

    /// Applies the edit, checks the result, and checks that undoing it gives the original back.
    private func expectEdit(_ edit: TextEdit?, on text: String, gives expected: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        guard let edit else {
            Issue.record("no edit", sourceLocation: sourceLocation)
            return
        }
        let result = edit.applied(to: text)
        #expect(result == expected, sourceLocation: sourceLocation)
        #expect(edit.inverse(in: text).applied(to: result) == text, sourceLocation: sourceLocation)
    }

    // MARK: Comment Line

    @Test func commentsTheCaretLine() {
        let text = "SELECT 1;\nSELECT 2;"
        let edit = SQLEditing.toggleComment(text, selection: NSRange(location: 12, length: 0))
        expectEdit(edit, on: text, gives: "SELECT 1;\n-- SELECT 2;")
        #expect(edit?.selection == NSRange(location: 15, length: 0)) // the caret stays on its character
    }

    @Test func uncommentsTheCaretLine() {
        let text = "-- SELECT 1;\n#SELECT 2;"
        expectEdit(SQLEditing.toggleComment(text, selection: NSRange(location: 5, length: 0)), on: text,
                   gives: "SELECT 1;\n#SELECT 2;")
        expectEdit(SQLEditing.toggleComment(text, selection: NSRange(location: 14, length: 0)), on: text,
                   gives: "-- SELECT 1;\nSELECT 2;")
    }

    @Test func commentsSelectedLinesAtTheirSmallestIndent() {
        let text = "SELECT *\n  FROM t\n\n    WHERE id = 1;\nSELECT 2;"
        // The selection ends at the start of "SELECT 2", which stays out, as in Xcode.
        let selection = NSRange(location: 0, length: (text as NSString).range(of: "SELECT 2").location)
        let edit = SQLEditing.toggleComment(text, selection: selection)
        expectEdit(edit, on: text, gives: "-- SELECT *\n--   FROM t\n\n--     WHERE id = 1;\nSELECT 2;")
        // Run again on the result: back to the original.
        let commented = edit!.applied(to: text)
        expectEdit(SQLEditing.toggleComment(commented, selection: edit!.selection), on: commented, gives: text)
    }

    @Test func mixedLinesAreCommentedNotUncommented() {
        let text = "-- a\nb"
        expectEdit(SQLEditing.toggleComment(text, selection: NSRange(location: 0, length: 6)), on: text,
                   gives: "-- -- a\n-- b")
    }

    @Test func blankLineHasNothingToComment() {
        #expect(SQLEditing.toggleComment("SELECT 1;\n\nSELECT 2;", selection: NSRange(location: 10, length: 0)) == nil)
        #expect(SQLEditing.toggleComment("", selection: NSRange(location: 0, length: 0)) == nil)
    }

    // MARK: Comment Current Statement

    @Test func commentsAndUncommentsTheCurrentStatement() {
        let text = "SELECT 1;\nSELECT *\nFROM t;\nSELECT 3;"
        let caret = NSRange(location: range(text, of: "FROM").location, length: 0)
        let edit = SQLEditing.toggleStatementComment(text, selection: caret)
        expectEdit(edit, on: text, gives: "SELECT 1;\n-- SELECT *\n-- FROM t;\nSELECT 3;")
        let commented = edit!.applied(to: text)
        let back = SQLEditing.toggleStatementComment(commented, selection: NSRange(location: range(commented, of: "FROM").location, length: 0))
        expectEdit(back, on: commented, gives: text)
    }

    // MARK: Shift

    @Test func shiftRightAndLeftOnTheCaretLine() {
        let text = "SELECT 1;\nFROM t"
        let right = SQLEditing.shiftRight(text, selection: NSRange(location: 12, length: 0))
        expectEdit(right, on: text, gives: "SELECT 1;\n\tFROM t")
        #expect(right?.selection == NSRange(location: 13, length: 0))
        let shifted = right!.applied(to: text)
        expectEdit(SQLEditing.shiftLeft(shifted, selection: right!.selection), on: shifted, gives: text)
    }

    @Test func shiftSelectedLinesAndKeepBlankLinesEmpty() {
        let text = "a\n\n  b\nc"
        let right = SQLEditing.shiftRight(text, selection: NSRange(location: 0, length: 6))
        expectEdit(right, on: text, gives: "\ta\n\n\t  b\nc")
        #expect(right?.selection == NSRange(location: 0, length: 8))
        let left = SQLEditing.shiftLeft("    a\n      b\n\tc", selection: NSRange(location: 0, length: 16))
        expectEdit(left, on: "    a\n      b\n\tc", gives: "a\n  b\nc")
    }

    @Test func shiftLeftWithNothingToRemoveDoesNothing() {
        #expect(SQLEditing.shiftLeft("SELECT 1;", selection: NSRange(location: 3, length: 0)) == nil)
    }

    // MARK: Select Current Statement

    @Test func currentStatementIsWhatRunCurrentStatementRuns() {
        let text = "SELECT 1;\n\nSELECT *\nFROM t;"
        #expect(SQLEditing.currentStatement(text, at: 0) == NSRange(location: 0, length: 8))
        #expect(SQLEditing.currentStatement(text, at: range(text, of: "FROM").location) == range(text, of: "SELECT *\nFROM t"))
        #expect(SQLEditing.currentStatement("", at: 0) == nil)
    }

    // MARK: Uppercase keywords

    private func upper(_ text: String, _ typed: String = " ") -> String? {
        SQLEditing.uppercaseKeyword(text, before: (text as NSString).length, typed: typed).map { $0.applied(to: text) }
    }

    @Test func uppercasesAKeywordWhenTheWordEnds() {
        #expect(upper("select") == "SELECT")
        #expect(upper("SELECT * from") == "SELECT * FROM")
        #expect(upper("SELECT * FROM t where", "\n") == "SELECT * FROM t WHERE")
        #expect(upper("SELECT count", "(") == "SELECT COUNT")
        let edit = SQLEditing.uppercaseKeyword("select", before: 6, typed: " ")
        expectEdit(edit, on: "select", gives: "SELECT")
    }

    @Test func leavesNamesStringsAndCommentsAlone() {
        #expect(upper("SELECT name") == nil)             // not a keyword
        #expect(upper("SELECT status") == nil)           // a keyword that is often a column
        #expect(upper("SELECT count") == nil)            // a function, but no "(" follows
        #expect(upper("SELECT o.from") == nil)           // after a dot
        #expect(upper("SELECT 'select") == nil)          // inside a string
        #expect(upper("-- select") == nil)               // inside a comment
        #expect(upper("SELECT `from") == nil)            // inside backticks
        #expect(upper("SELECT") == nil)                  // already uppercase
        #expect(upper("sel", "e") == nil)                // still typing the word
    }

    // MARK: Matching brackets and quotes

    private func pair(_ text: String, at caret: Int, _ typed: String, linked: Bool = false, length: Int = 0) -> SQLEditing.PairAction? {
        SQLEditing.pair(text, selection: NSRange(location: caret, length: length), typed: typed, nextIsLinked: linked)
    }

    @Test func openerInsertsItsMatch() {
        guard case .insertPair(let edit, let linked)? = pair("SELECT COUNT", at: 12, "(") else {
            Issue.record("no pair"); return
        }
        expectEdit(edit, on: "SELECT COUNT", gives: "SELECT COUNT()")
        #expect(edit.selection == NSRange(location: 13, length: 0))
        #expect(linked == NSRange(location: 13, length: 1))
        guard case .insertPair(let quote, _)? = pair("WHERE a = ", at: 10, "'") else {
            Issue.record("no quote pair"); return
        }
        #expect(quote.applied(to: "WHERE a = ") == "WHERE a = ''")
    }

    @Test func typingTheLinkedCloserStepsOverIt() {
        #expect(pair("COUNT()", at: 6, ")", linked: true) == .skip(NSRange(location: 7, length: 0)))
        #expect(pair("''", at: 1, "'", linked: true) == .skip(NSRange(location: 2, length: 0)))
        // A closer that was typed, not inserted, is not stepped over.
        #expect(pair("COUNT()", at: 6, ")", linked: false) == nil)
    }

    @Test func selectionIsWrapped() {
        guard case .wrap(let edit)? = pair("SELECT a + b", at: 7, "(", length: 5) else {
            Issue.record("no wrap"); return
        }
        expectEdit(edit, on: "SELECT a + b", gives: "SELECT (a + b)")
        #expect(edit.selection == NSRange(location: 8, length: 5))
    }

    @Test func noPairBeforeAWordInsideAStringOrForAnApostrophe() {
        #expect(pair("SELECT name", at: 7, "(") == nil)          // before a word
        #expect(pair("WHERE a = 'it", at: 13, "(") == nil)       // inside a string
        #expect(pair("-- note ", at: 8, "'") == nil)              // inside a comment
        #expect(pair("WHERE a = 'don", at: 14, "'") == nil)      // an apostrophe after a word
        #expect(pair("SELECT 1", at: 8, ";") == nil)             // not a pair character
    }

    @Test func deleteInsideAnEmptyLinkedPairRemovesBoth() {
        #expect(SQLEditing.deletesPair("COUNT()", caret: 6, nextIsLinked: true) == NSRange(location: 5, length: 2))
        #expect(SQLEditing.deletesPair("COUNT()", caret: 6, nextIsLinked: false) == nil)
        #expect(SQLEditing.deletesPair("COUNT(a)", caret: 7, nextIsLinked: true) == nil)
    }

    // MARK: Indent new lines

    @Test func newLineKeepsTheIndent() {
        #expect(SQLEditing.indentation("SELECT *\n\t  FROM t", at: 18) == "\t  ")
        #expect(SQLEditing.indentation("SELECT *", at: 8) == "")
        #expect(SQLEditing.indentation("  ab", at: 1) == " ")
    }
}
