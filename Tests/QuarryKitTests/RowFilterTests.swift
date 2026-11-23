import Foundation
import Testing
@testable import QuarryKit

struct RowFilterTests {
    private func clause(_ op: RowFilter.Operator, _ value: String = "", _ second: String = "", column: String = "name") -> String? {
        RowFilter(column: column, op: op, value: value, secondValue: second).whereClause
    }

    @Test func comparisons() {
        #expect(clause(.equals, "Kat") == "`name` = 'Kat'")
        #expect(clause(.notEquals, "Kat") == "`name` != 'Kat'")
        #expect(clause(.greater, "10") == "`name` > '10'")
        #expect(clause(.less, "10") == "`name` < '10'")
        #expect(clause(.greaterOrEqual, "10") == "`name` >= '10'")
        #expect(clause(.lessOrEqual, "10") == "`name` <= '10'")
        #expect(clause(.equals) == nil)
        #expect(clause(.contains) == nil)
        #expect(clause(.equals, " ") == "`name` = ' '")
    }

    @Test func patterns() {
        #expect(clause(.like, "K_t%") == "`name` LIKE 'K_t%'")
        #expect(clause(.notLike, "K%") == "`name` NOT LIKE 'K%'")
        #expect(clause(.contains, "at") == "`name` LIKE '%at%'")
        #expect(clause(.notContains, "at") == "`name` NOT LIKE '%at%'")
        #expect(clause(.startsWith, "Ka") == "`name` LIKE 'Ka%'")
        #expect(clause(.endsWith, "at") == "`name` LIKE '%at'")
    }

    @Test func containsMatchesWildcardsLiterally() {
        // 50% off_now\ -> pattern 50\% off\_now\\, then quoted (backslashes doubled).
        #expect(clause(.contains, #"50% off_now\"#) == #"`name` LIKE '%50\\% off\\_now\\\\%'"#)
    }

    @Test func inListsEachValue() {
        #expect(clause(.isIn, " 1, 2 ,,3 ") == "`name` IN ('1', '2', '3')")
        #expect(clause(.isIn, "a'b, c") == #"`name` IN ('a\'b', 'c')"#)
        #expect(clause(.isIn, " , ") == nil)
    }

    @Test func betweenNeedsBothValues() {
        #expect(clause(.between, "2024-01-01", " 2024-12-31 ") == "`name` BETWEEN '2024-01-01' AND '2024-12-31'")
        #expect(clause(.between, "1") == nil)
        #expect(clause(.between, "", "9") == nil)
    }

    @Test func nullTests() {
        #expect(clause(.isNull, "ignored") == "`name` IS NULL")
        #expect(clause(.isNotNull) == "`name` IS NOT NULL")
    }

    @Test func injectionStaysInsideTheLiteral() {
        #expect(clause(.equals, "x' OR '1'='1") == #"`name` = 'x\' OR \'1\'=\'1'"#)
        #expect(clause(.equals, "a\\' OR 1 -- ") == #"`name` = 'a\\\' OR 1 -- '"#)
        #expect(clause(.isNull, column: "we`ird") == "`we``ird` IS NULL")
    }

    @Test func needsAColumn() {
        #expect(clause(.equals, "x", column: "") == nil)
        #expect(!RowFilter(column: "").isSet)
    }

    @Test func pageSQLAddsTheWhereClause() {
        let sql = MySQLDialect().pageSQL(table: "t", database: "d", where: "`a` = '1'", orderBy: "b", ascending: false,
                                         offset: 0, limit: 10)
        #expect(sql == "SELECT * FROM `d`.`t` WHERE `a` = '1' ORDER BY `b` DESC LIMIT 0, 10")
    }
}

struct FilteredLabelTests {
    @Test func countsMatchesAgainstTheTable() {
        #expect(Paging(total: 312, pageSize: 1000).filteredLabel(unfiltered: 100_000) == "312 of 100,000 rows")
        #expect(Paging(total: 0, pageSize: 1000).filteredLabel(unfiltered: 1) == "0 of 1 row")
        #expect(Paging(total: 5312, pageSize: 1000, page: 1).filteredLabel(unfiltered: 100_000)
            == "Rows 1,001–2,000 · 5,312 of 100,000 rows")
    }
}

struct FilterIndexTests {
    @Test func indexUse() {
        let indexed: Set<String> = ["id", "email"]
        #expect(RowFilter(column: "id", op: .equals, value: "1").canUseIndex(indexed: indexed))
        #expect(RowFilter(column: "email", op: .startsWith, value: "a").canUseIndex(indexed: indexed))
        #expect(!RowFilter(column: "email", op: .contains, value: "a").canUseIndex(indexed: indexed))
        #expect(!RowFilter(column: "name", op: .equals, value: "a").canUseIndex(indexed: indexed))
        #expect(FilterDefaults.delay(for: [RowFilter(column: "id", value: "1")], indexed: indexed) == .milliseconds(500))
        #expect(FilterDefaults.delay(for: [RowFilter(column: "id", value: "1"), RowFilter(column: "name", value: "x")],
                                     indexed: indexed) == .milliseconds(1000))
    }

    @Test func defaultColumn() {
        func field(_ name: String, key: String = "", extra: String = "") -> FieldInfo {
            FieldInfo(name: name, fullType: "int(11)", isNullable: false, key: key, defaultValue: nil, extra: extra,
                      collation: nil, comment: "")
        }
        #expect(FilterDefaults.column([field("a"), field("id", key: "PRI", extra: "auto_increment")]) == "id")
        #expect(FilterDefaults.column([field("a"), field("k", key: "MUL"), field("code", key: "PRI")]) == "code")
        #expect(FilterDefaults.column([field("a"), field("k", key: "MUL"), field("u", key: "UNI")]) == "u")
        #expect(FilterDefaults.column([field("a"), field("k", key: "MUL")]) == "k")
        #expect(FilterDefaults.column([field("a"), field("b")]) == "a")
        #expect(FilterDefaults.column([]) == nil)
    }
}
