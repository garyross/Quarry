import Foundation
import Testing
@testable import QuarryKit

@Suite("Rename, duplicate, empty and delete a table")
struct TableEditTests {
    let create = """
        CREATE TABLE `order_items` (
          `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
          `order_id` int(10) unsigned NOT NULL,
          PRIMARY KEY (`id`),
          KEY `order_id` (`order_id`),
          CONSTRAINT `order_items_ibfk_1` FOREIGN KEY (`order_id`) REFERENCES `orders` (`id`) ON DELETE CASCADE,
          CONSTRAINT `qty_positive` CHECK (`id` > 0)
        ) ENGINE=InnoDB AUTO_INCREMENT=42 DEFAULT CHARSET=utf8mb4
        """

    @Test func aCopyHasTheNewNameAndUnnamedForeignKeys() {
        let sql = TableEdit.copyCreateSQL(create, to: "order_items_copy", in: "shop", withRows: true)
        #expect(sql.hasPrefix("CREATE TABLE `shop`.`order_items_copy` (\n"))
        #expect(sql.contains("  FOREIGN KEY (`order_id`) REFERENCES `orders` (`id`) ON DELETE CASCADE"))
        #expect(!sql.contains("order_items_ibfk_1"))
        // CHECK names belong to the table, so they stay.
        #expect(sql.contains("CONSTRAINT `qty_positive` CHECK"))
        #expect(sql.contains("AUTO_INCREMENT=42"))
    }

    @Test func aCopyWithoutRowsCountsFromOne() {
        let sql = TableEdit.copyCreateSQL(create, to: "empty", in: "shop", withRows: false)
        #expect(!sql.contains("AUTO_INCREMENT=42"))
        #expect(sql.contains("`id` int(10) unsigned NOT NULL AUTO_INCREMENT,"))
    }

    @Test func copyNamesSkipTakenOnes() {
        #expect(TableEdit.copyName(for: "orders", existing: ["orders"]) == "orders_copy")
        #expect(TableEdit.copyName(for: "orders", existing: ["orders", "Orders_Copy"]) == "orders_copy2")
        #expect(TableEdit.copyName(for: "orders", existing: ["orders_copy", "orders_copy2"]) == "orders_copy3")
        let long = String(repeating: "a", count: 64)
        #expect(TableEdit.copyName(for: long, existing: []).count == 64)
    }

    @Test func deleteGroupsTablesAndViews() {
        let objects = [DBObject(name: "a", kind: .table), DBObject(name: "v", kind: .view),
                       DBObject(name: "b`c", kind: .table)]
        #expect(TableEdit.deleteSQL(objects, in: "shop", engine: .mysql) == [
            "DROP TABLE `shop`.`a`, `shop`.`b``c`", "DROP VIEW `shop`.`v`",
        ])
        let routines = [DBObject(name: "p", kind: .procedure), DBObject(name: "f", kind: .function), DBObject(name: "q", kind: .procedure)]
        #expect(TableEdit.deleteSQL(routines, in: "shop", engine: .mysql) == [
            "DROP PROCEDURE `shop`.`p`", "DROP FUNCTION `shop`.`f`", "DROP PROCEDURE `shop`.`q`",
        ])
        #expect(TableEdit.renameSQL("a", to: "b", in: "shop", engine: .mysql) == "RENAME TABLE `shop`.`a` TO `shop`.`b`")
        #expect(TableEdit.emptySQL("a", in: "shop", engine: .mysql) == "TRUNCATE TABLE `shop`.`a`")
    }

    @Test func foreignKeyRefusalsAreRecognized() {
        #expect(TableEdit.isForeignKeyError("Cannot truncate a table referenced in a foreign key constraint (`quarry_demo`.`order_items`, CONSTRAINT `1`)"))
        #expect(TableEdit.isForeignKeyError("Cannot delete or update a parent row: a foreign key constraint fails"))
        #expect(!TableEdit.isForeignKeyError("Table 'x' doesn't exist"))
    }
}
