import Foundation
import Testing
@testable import QuarryKit

struct ResultEditingTests {
    let customers = ResultEditing.Source(database: "quarry_demo", table: "customers")
    let orders = ResultEditing.Source(database: "quarry_demo", table: "orders")

    func column(_ name: String, _ table: String = "customers", org: String? = nil) -> ResultColumn {
        ResultColumn(name: name, table: table, database: table.isEmpty ? "" : "quarry_demo", orgName: table.isEmpty ? "" : (org ?? name))
    }

    @Test func oneTableWithItsKeyIsEditable() {
        let columns = [column("id"), column("label", org: "name"), column("total", "")]
        let editing = ResultEditing(columns: columns, primaryKeys: [customers: ["id"]], engine: .mysql)
        #expect(editing.source(column: 0) == customers)
        #expect(editing.source(column: 1) == customers)
        #expect(editing.reason(column: 2) == "Read-only: computed by the query, not stored in a table.")
        let row: [CellValue] = [.text("4"), .text("Kat"), .text("9")]
        #expect(editing.updateSQL(row: row, column: 1, value: .text("Kit"))
            == "UPDATE `quarry_demo`.`customers` SET `name` = 'Kit' WHERE `id` = '4'")
        #expect(editing.updateSQL(row: row, column: 2, value: .text("1")) == nil)
        #expect(editing.refetchSQL(source: customers, row: row)
            == "SELECT `id`, `name` FROM `quarry_demo`.`customers` WHERE `id` = '4' LIMIT 1")
        #expect(editing.refetchColumns(source: customers) == [[0], [1]])
    }

    @Test func joinIsEditableOnlyWhereTheKeyIsSelected() {
        let columns = [column("id", "orders"), column("status", "orders"), column("name")]
        let editing = ResultEditing(columns: columns, primaryKeys: [customers: ["id"], orders: ["id"]], engine: .mysql)
        #expect(ResultEditing.sources(of: columns) == [orders, customers])
        #expect(editing.source(column: 1) == orders)
        #expect(editing.reason(column: 2)
            == "Read-only: add id (the primary key of customers) to the SELECT to edit this column.")
    }

    @Test func tablesWithoutAKeyOrLookupAreReadOnly() {
        let columns = [column("id"), column("x", "t2")]
        let editing = ResultEditing(columns: columns, primaryKeys: [customers: []], engine: .mysql)
        #expect(editing.reason(column: 0) == "Read-only: customers has no primary key, so its rows can't be found to save a change.")
        #expect(editing.reason(column: 1) == "Read-only: t2 is not a table that can be edited.")
        #expect(!editing.hasEditableColumns)
    }

    @Test func aFieldSelectedTwiceChangesInBoth() {
        let columns = [column("id"), column("name"), column("again", org: "name")]
        let editing = ResultEditing(columns: columns, primaryKeys: [customers: ["ID"]], engine: .mysql)
        let row: [CellValue] = [.text("1"), .text("a"), .text("a")]
        #expect(editing.applying(.text("b"), column: 2, to: row) == [.text("1"), .text("b"), .text("b")])
        #expect(editing.refetchColumns(source: customers) == [[0], [1, 2]])
        #expect(editing.sameRow(row, [.text("1"), .null, .null], source: customers))
        #expect(!editing.sameRow(row, [.text("2"), .text("a"), .text("a")], source: customers))
    }

    @Test func compositeKeyMatchesOnEveryPart() {
        let columns = [column("order_id", "order_items"), column("product_id", "order_items"), column("qty", "order_items")]
        let items = ResultEditing.Source(database: "quarry_demo", table: "order_items")
        let editing = ResultEditing(columns: columns, primaryKeys: [items: ["order_id", "product_id"]], engine: .mysql)
        #expect(editing.updateSQL(row: [.text("1"), .text("2"), .text("3")], column: 2, value: .null)
            == "UPDATE `quarry_demo`.`order_items` SET `qty` = NULL WHERE `order_id` = '1' AND `product_id` = '2'")
        let partial = ResultEditing(columns: Array(columns.dropFirst()), primaryKeys: [items: ["order_id", "product_id"]], engine: .mysql)
        #expect(!partial.hasEditableColumns)
    }
}
