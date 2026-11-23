import Foundation
import Testing
@testable import QuarryKit

@Suite("Rename, duplicate and alter a database")
struct DatabaseTransferTests {
    @Test func definitionsPointAtTheNewDatabase() {
        let view = "CREATE ALGORITHM=UNDEFINED DEFINER=`gary`@`localhost` SQL SECURITY DEFINER VIEW `shop`.`totals` AS "
            + "select `o`.`id` AS `id` from (`shop`.`orders` `o` join `shop`.`customers` `c`) where `c`.`name` = 'shop'"
        let moved = DatabaseTransfer.retarget(view, from: "shop", to: "shop 2")
        #expect(moved.contains("VIEW `shop 2`.`totals`"))
        #expect(moved.contains("`shop 2`.`orders` `o`"))
        #expect(moved.contains("`shop 2`.`customers`"))
        // A column alias or a string that only looks like the name stays.
        #expect(moved.contains("`c`.`name` = 'shop'"))
        #expect(!moved.contains("`shop`."))
    }

    @Test func aNameWithABacktickIsQuotedTheSameWay() {
        let sql = "CREATE VIEW `we``ird`.`v` AS select 1 from `we``ird`.`t`"
        #expect(DatabaseTransfer.retarget(sql, from: "we`ird", to: "new") == "CREATE VIEW `new`.`v` AS select 1 from `new`.`t`")
    }

    @Test func aCopyWithoutRowsCountsFromOne() {
        let create = """
            CREATE TABLE `orders` (
              `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
              PRIMARY KEY (`id`)
            ) ENGINE=InnoDB AUTO_INCREMENT=6 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            """
        let copy = DatabaseTransfer.withoutAutoIncrement(create)
        #expect(copy.contains("NOT NULL AUTO_INCREMENT,"))
        #expect(copy.hasSuffix(") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci"))
        #expect(DatabaseTransfer.withoutAutoIncrement("CREATE TABLE `t` (`a` int)") == "CREATE TABLE `t` (`a` int)")
    }

    @Test func tablesMoveInOneStatement() {
        #expect(DatabaseTransfer.renameTablesSQL(["a", "b"], from: "old", to: "new")
            == "RENAME TABLE `old`.`a` TO `new`.`a`, `old`.`b` TO `new`.`b`")
    }

    @Test func rowsSkipGeneratedColumns() {
        #expect(DatabaseTransfer.isGenerated(extra: "VIRTUAL GENERATED"))
        #expect(DatabaseTransfer.isGenerated(extra: "STORED GENERATED"))
        #expect(DatabaseTransfer.isGenerated(extra: "PERSISTENT"))
        #expect(!DatabaseTransfer.isGenerated(extra: "auto_increment"))
        #expect(!DatabaseTransfer.isGenerated(extra: "on update current_timestamp()"))
        #expect(DatabaseTransfer.copyRowsSQL(table: "t", columns: ["id", "name"], from: "a", to: "b")
            == "INSERT INTO `b`.`t` (`id`, `name`) SELECT `id`, `name` FROM `a`.`t`")
    }

    @Test func systemDatabasesAreProtected() {
        #expect(DatabaseTransfer.isSystem("mysql"))
        #expect(DatabaseTransfer.isSystem("INFORMATION_SCHEMA"))
        #expect(DatabaseTransfer.isSystem("sys"))
        #expect(!DatabaseTransfer.isSystem("quarry_demo"))
    }

    @Test func alterNamesTheCollationOnlyWhenChosen() {
        #expect(AlterDatabase(name: "shop", charset: "latin1").sql == "ALTER DATABASE `shop` CHARACTER SET `latin1`")
        #expect(AlterDatabase(name: "shop", charset: "utf8mb4", collation: "utf8mb4_bin").sql
            == "ALTER DATABASE `shop` CHARACTER SET `utf8mb4` COLLATE `utf8mb4_bin`")
    }
}
