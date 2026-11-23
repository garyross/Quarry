import Foundation
import Testing
@testable import QuarryKit

@Suite("Statement splitter")
struct StatementSplitterTests {
    @Test func splitsOnSemicolons() {
        let statements = StatementSplitter.split("SELECT 1;\nSELECT 2;  \n\nSELECT 3")
        #expect(statements.map(\.text) == ["SELECT 1", "SELECT 2", "SELECT 3"])
        #expect(statements.map(\.line) == [1, 2, 4])
    }

    @Test func ignoresSemicolonsInStringsAndComments() throws {
        let sql = """
        SELECT 'a;b', "c;d", `e;f` FROM t; -- one; two
        # three; four
        /* five; six */ SELECT 'it''s; fine', 'back\\';slash';
        """
        let statements = StatementSplitter.split(sql)
        // The comments belong to the statement after them: two statements.
        try #require(statements.count == 2)
        #expect(statements[0].text == "SELECT 'a;b', \"c;d\", `e;f` FROM t")
        #expect(statements[1].text.hasPrefix("-- one; two"))
        #expect(statements[1].text.hasSuffix("'back\\';slash'"))
    }

    @Test func doubleDashNeedsASpace() {
        #expect(StatementSplitter.split("SELECT 5--3; SELECT 2").map(\.text) == ["SELECT 5--3", "SELECT 2"])
    }

    @Test func delimiterBlocks() {
        let sql = """
        DELIMITER //
        CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END//
        DELIMITER ;
        SELECT 3;
        """
        let statements = StatementSplitter.split(sql)
        #expect(statements.map(\.text) == ["CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END", "SELECT 3"])
        #expect(statements[0].line == 2)
    }

    @Test func statementAtCursor() {
        let sql = "SELECT 1;\nSELECT 2;\n"
        let statements = StatementSplitter.split(sql)
        #expect(StatementSplitter.statement(at: 3, in: statements)?.text == "SELECT 1")
        #expect(StatementSplitter.statement(at: 9, in: statements)?.text == "SELECT 2")   // right after ";": the next line's statement
        #expect(StatementSplitter.statement(at: 14, in: statements)?.text == "SELECT 2")
        #expect(StatementSplitter.statement(at: (sql as NSString).length, in: statements)?.text == "SELECT 2")
    }

    @Test func utf16Ranges() {
        let sql = "SELECT '🌸';\nSELECT 2"
        let statements = StatementSplitter.split(sql)
        #expect((sql as NSString).substring(with: statements[1].range) == "SELECT 2")
    }
}

@Suite("Quoting")
struct QuoteTests {
    @Test func identifiers() {
        #expect(SQLQuote.identifier("order") == "`order`")
        #expect(SQLQuote.identifier("we`ird") == "`we``ird`")
        #expect(SQLQuote.qualified("db", "t") == "`db`.`t`")
    }

    @Test func literals() {
        #expect(SQLQuote.mysqlLiteral("it's") == "'it\\'s'")
        #expect(SQLQuote.mysqlLiteral("a\\b\nc") == "'a\\\\b\\nc'")
    }
}

@Suite("Highlighter")
struct HighlighterTests {
    @Test func findsTokenKinds() {
        let sql = "SELECT `id`, 'x', 42, @v FROM t1 -- note"
        let kinds = SQLHighlighter.tokens(in: sql).map(\.kind)
        #expect(kinds == [.keyword, .identifier, .string, .number, .variable, .keyword, .comment])
    }
}

@Suite("Cancelled status")
struct CancelledStatusTests {
    @Test func oneStatement() {
        #expect(StatementResult.cancelledStatus(ran: 0, of: 1, after: .milliseconds(1204)) == "Query cancelled · 1.204 s")
    }

    @Test func runAllNamesTheStatement() {
        #expect(StatementResult.cancelledStatus(ran: 2, of: 5, after: .seconds(3)) == "Cancelled in statement 3 of 5 · 3.000 s")
        // Cancelled after the last one finished: still names the last.
        #expect(StatementResult.cancelledStatus(ran: 5, of: 5, after: .seconds(1)) == "Cancelled in statement 5 of 5 · 1.000 s")
    }
}
