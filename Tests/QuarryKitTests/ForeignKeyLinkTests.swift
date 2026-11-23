import Foundation
import Testing
@testable import QuarryKit

struct ForeignKeyLinkTests {
    func key(_ name: String, _ columns: String, _ table: String, _ referenced: String, db: String = "shop") -> ForeignKeyInfo {
        ForeignKeyInfo(name: name, columns: columns, referencedDatabase: db, referencedTable: table,
                       referencedColumns: referenced, onUpdate: "CASCADE", onDelete: "RESTRICT")
    }

    @Test func eachFieldLinksThroughTheFirstKeyThatStartsWithIt() {
        let links = ForeignKeyLink.links([
            key("fk_a", "order_id", "orders", "id"),
            key("fk_b", "order_id, product_id", "order_lines", "order_id, product_id"),
            key("fk_c", "product_id", "products", "id"),
        ])
        #expect(links.count == 2)
        #expect(links["order_id"] == ForeignKeyLink(column: "order_id", database: "shop", table: "orders", referencedColumn: "id"))
        #expect(links["product_id"]?.table == "products")
    }

    @Test func aKeyOnSeveralFieldsLinksFromItsFirstField() {
        let links = ForeignKeyLink.links([key("fk", "a, b", "pairs", "x, y")])
        #expect(links["a"]?.referencedColumn == "x")
        #expect(links["b"] == nil)
    }

    @Test func theFilterMatchesTheValue() {
        let link = ForeignKeyLink(column: "order_id", database: "shop", table: "orders", referencedColumn: "id")
        #expect(link.filter(for: .text("42"))?.whereClause == "`id` = '42'")
        #expect(link.filter(for: .null) == nil)
        #expect(!ForeignKeyLink.canFollow(.null))
        #expect(ForeignKeyLink.canFollow(.text("0")))
    }

    @Test func bytesCompareAsHex() {
        let link = ForeignKeyLink(column: "uuid", database: "shop", table: "things", referencedColumn: "uuid")
        let clause = link.filter(for: .binary(Data([0x0A, 0xFF])))?.whereClause
        #expect(clause?.contains("`uuid` = 0x0AFF") == true)
    }

    @Test func helpNamesTheTableAndValue() {
        let link = ForeignKeyLink(column: "customer_id", database: "shop", table: "customers", referencedColumn: "id")
        #expect(link.help(for: .text("3"), from: "shop") == "Open the customers row where id = 3")
        #expect(link.help(for: .text("3"), from: "other") == "Open the shop.customers row where id = 3")
    }
}

struct HistoryTests {
    @Test func backAndForwardRetraceTheVisits() {
        var history = History<String>()
        history.visit(leaving: "a")
        history.visit(leaving: "b")
        #expect(history.goBack(from: "c") == "b")
        #expect(history.goBack(from: "b") == "a")
        #expect(!history.canGoBack)
        #expect(history.goForward(from: "a") == "b")
        #expect(history.goForward(from: "b") == "c")
        #expect(!history.canGoForward)
    }

    @Test func aNewVisitDropsTheForwardPlaces() {
        var history = History<String>()
        history.visit(leaving: "a")
        _ = history.goBack(from: "b")
        #expect(history.canGoForward)
        history.visit(leaving: "a")
        #expect(!history.canGoForward)
        #expect(history.back == ["a"])
    }

    @Test func theOldestPlacesGoPastTheLimit() {
        var history = History<Int>(limit: 2)
        for place in 1...4 { history.visit(leaving: place) }
        #expect(history.back == [3, 4])
    }
}
