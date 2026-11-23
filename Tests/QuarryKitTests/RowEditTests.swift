import Foundation
import Testing
@testable import QuarryKit

struct RowEditTests {
    let keyed = [ResultColumn(name: "id", isNumeric: true, isPrimaryKey: true), ResultColumn(name: "name"),
                 ResultColumn(name: "odd`name")]

    @Test func updateUsesThePrimaryKey() {
        let sql = RowEdit.updateSQL(database: "quarry_demo", table: "customers", columns: keyed,
                                    row: [.text("4"), .text("Kat"), .null], changes: [1: .text("O'Brien \\ \"x\"")], engine: .mysql)
        #expect(sql == #"UPDATE `quarry_demo`.`customers` SET `name` = 'O\'Brien \\ "x"' WHERE `id` = '4'"#)
    }

    @Test func identifiersAreQuoted() {
        let sql = RowEdit.updateSQL(database: "my`db", table: "t`1", columns: keyed,
                                    row: [.text("1"), .text("a"), .text("b")], changes: [2: .text("c")], engine: .mysql)
        #expect(sql == "UPDATE `my``db`.`t``1` SET `odd``name` = 'c' WHERE `id` = '1'")
    }

    @Test func compositeKeyUsesEveryKeyColumn() {
        let columns = [ResultColumn(name: "order_id", isPrimaryKey: true), ResultColumn(name: "product_id", isPrimaryKey: true),
                       ResultColumn(name: "qty")]
        let sql = RowEdit.updateSQL(database: "d", table: "t", columns: columns,
                                    row: [.text("1"), .text("2"), .text("3")], changes: [2: .text("5")], engine: .mysql)
        #expect(sql == "UPDATE `d`.`t` SET `qty` = '5' WHERE `order_id` = '1' AND `product_id` = '2'")
    }

    @Test func noKeyMatchesAllColumnsWithLimit() {
        let columns = [ResultColumn(name: "a"), ResultColumn(name: "b"), ResultColumn(name: "c", isBinary: true)]
        let sql = RowEdit.updateSQL(database: "d", table: "t", columns: columns,
                                    row: [.text("x"), .null, .binary(Data([0x00, 0xFF]))], changes: [0: .text("y")], engine: .mysql)
        #expect(sql == "UPDATE `d`.`t` SET `a` = 'y' WHERE `a` = 'x' AND `b` IS NULL AND `c` = X'00FF' LIMIT 1")
    }

    @Test func nullIsWrittenAsNull() {
        let sql = RowEdit.updateSQL(database: "d", table: "t", columns: keyed,
                                    row: [.text("1"), .text("a"), .text("b")], changes: [1: .null], engine: .mysql)
        #expect(sql == "UPDATE `d`.`t` SET `name` = NULL WHERE `id` = '1'")
    }

    // MARK: S-010

    @Test func insertNamesOnlyTheGivenColumns() {
        let sql = RowEdit.insertSQL(database: "d", table: "t", values: [("name", .text("Kat")), ("odd`name", .null)], engine: .mysql)
        #expect(sql == "INSERT INTO `d`.`t` (`name`, `odd``name`) VALUES ('Kat', NULL)")
        #expect(RowEdit.insertSQL(database: "d", table: "t", values: [], engine: .mysql) == "INSERT INTO `d`.`t` () VALUES ()")
    }

    @Test func deleteFindsOneRowByKey() {
        let sql = RowEdit.deleteSQL(database: "d", table: "t", columns: keyed, row: [.text("7"), .text("a"), .null], engine: .mysql)
        #expect(sql == "DELETE FROM `d`.`t` WHERE `id` = '7' LIMIT 1")
        let loose = [ResultColumn(name: "a"), ResultColumn(name: "b")]
        #expect(RowEdit.deleteSQL(database: "d", table: "t", columns: loose, row: [.text("x"), .null], engine: .mysql)
                == "DELETE FROM `d`.`t` WHERE `a` = 'x' AND `b` IS NULL LIMIT 1")
    }

    @Test func copyAsTabSeparatedValues() {
        let rows: [[CellValue]] = [[.text("1"), .text("a\tb"), .null], [.text("2"), .binary(Data([0xAB])), .flag(true)]]
        #expect(RowCopy.tabSeparated(columns: ["id", "name", "x"], rows: rows, names: false) == "1\ta b\tNULL\n2\t0xAB\t1")
        #expect(RowCopy.tabSeparated(columns: ["id", "name", "x"], rows: [rows[0]], names: true) == "id\tname\tx\n1\ta b\tNULL")
    }

    @Test func copyAsOneInsert() {
        let sql = RowCopy.insertStatement(table: "t", columns: ["id", "name"], rows: [[.text("1"), .text("O'B")], [.text("2"), .null]], engine: .mysql)
        #expect(sql == "INSERT INTO `t` (`id`, `name`)\nVALUES\n\t('1', 'O\\'B'),\n\t('2', NULL);")
    }

    /// S-016: each format with NULL, quotes, tabs, newlines and binary data.
    @Test func copyFormatsKeepAwkwardValues() {
        let rows: [[CellValue]] = [
            [.text("1"), .text("it's \"x\""), .text("a\tb\nc"), .null],
            [.text("2"), .text("back\\slash"), .binary(Data([0x00, 0xFF])), .flag(false)],
        ]
        let columns = ["id", "quote", "mixed", "n"]
        #expect(RowCopy.tabSeparated(columns: columns, rows: rows, names: false)
                == "1\tit's \"x\"\ta b c\tNULL\n2\tback\\slash\t0x00FF\t0")
        #expect(RowCopy.tabSeparated(columns: columns, rows: rows, names: true)
                .hasPrefix("id\tquote\tmixed\tn\n1\t"))
        #expect(RowCopy.insertStatement(table: "t`x", columns: columns, rows: rows, engine: .mysql)
                == "INSERT INTO `t``x` (`id`, `quote`, `mixed`, `n`)\nVALUES\n"
                + "\t('1', 'it\\'s \"x\"', 'a\tb\\nc', NULL),\n"
                + "\t('2', 'back\\\\slash', X'00FF', 0);")
        // A SQLite file reads no backslash escapes: quotes are doubled, the rest kept as is.
        #expect(RowCopy.insertStatement(table: "t`x", columns: columns, rows: rows, engine: .sqlite)
                == "INSERT INTO `t``x` (`id`, `quote`, `mixed`, `n`)\nVALUES\n"
                + "\t('1', 'it''s \"x\"', 'a\tb\nc', NULL),\n"
                + "\t('2', 'back\\slash', X'00FF', 0);")
    }

    @Test func queryInsertNamesItsOneTable() {
        let one = [ResultColumn(name: "a", table: "orders"), ResultColumn(name: "b", table: "orders")]
        #expect(RowCopy.insertTable(for: one) == "orders")
        #expect(RowCopy.insertTable(for: one + [ResultColumn(name: "c", table: "customers")]) == "<table>")
        #expect(RowCopy.insertTable(for: [ResultColumn(name: "NOW()")]) == "<table>")
    }

    @Test func newRowStartsWithDefaults() {
        func field(_ null: Bool, _ value: String?, _ extra: String = "") -> FieldInfo {
            FieldInfo(name: "f", fullType: "int", isNullable: null, key: "", defaultValue: value, extra: extra, collation: nil, comment: "")
        }
        #expect(NewRow.initialValue(field(false, nil, "auto_increment")) == .null)
        #expect(NewRow.initialValue(field(false, "US")) == .text("US"))
        #expect(NewRow.initialValue(field(false, "current_timestamp()")) == .text("current_timestamp()"))
        #expect(NewRow.initialValue(field(true, nil)) == .null)
        #expect(NewRow.initialValue(field(true, "NULL")) == .null)
        #expect(NewRow.initialValue(field(false, nil)) == .text(""))
        #expect(NewRow.initialValue(field(true, nil, "VIRTUAL GENERATED")) == .null)
        #expect(!NewRow.copiesValue(field(false, nil, "auto_increment")))
    }
}
