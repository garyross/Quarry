import Foundation
import Testing
@testable import QuarryKit

struct SQLCompletionTests {
    let catalog = CompletionCatalog(
        databases: ["quarry_demo", "quarry_legacy", "select"],
        currentDatabase: "quarry_demo",
        tables: [
            "quarry_demo": [
                .init(name: "customers", columns: [.init(name: "id", type: "int(11)"), .init(name: "name", type: "varchar(100)")]),
                .init(name: "orders", columns: [.init(name: "id", type: "int(11)"), .init(name: "customer_id", type: "int(11)"),
                                                .init(name: "total", type: "decimal(10,2)")]),
                .init(name: "order_items", columns: [.init(name: "order_id", type: "int(11)")]),
                .init(name: "order_totals", isView: true, columns: [.init(name: "order_id", type: "int(11)")]),
            ],
        ])

    private func at(_ sql: String) -> SQLCompletion.Context {
        SQLCompletion.context(sql, cursor: (sql as NSString).length, catalog: catalog)
    }

    @Test func afterFromAreTables() {
        #expect(at("SELECT * FROM ord") == .tables(database: nil))
        #expect(at("SELECT * FROM orders o JOIN cu") == .tables(database: nil))
        #expect(at("SELECT * FROM orders, cu") == .tables(database: nil))
        #expect(at("INSERT INTO ") == .tables(database: nil))
        #expect(at("UPDATE ord") == .tables(database: nil))
        #expect(at("USE quar") == .databases)
    }

    @Test func afterAliasDotAreThatTablesColumns() {
        let sql = "SELECT o.cu FROM orders o"
        #expect(SQLCompletion.context(sql, cursor: 11, catalog: catalog) == .columns(table: "orders", database: nil))
        #expect(at("SELECT * FROM customers AS c WHERE c.") == .columns(table: "customers", database: nil))
        #expect(at("SELECT orders.") == .columns(table: "orders", database: nil))
        #expect(at("SELECT * FROM quarry_legacy.") == .tables(database: "quarry_legacy"))
        #expect(at("SELECT quarry_demo.orders.") == .columns(table: "orders", database: "quarry_demo"))
    }

    @Test func orderByDescIsNotATableKeyword() {
        #expect(at("SELECT * FROM orders ORDER BY id DESC LIM") == .any)
        #expect(at("DESC ord") == .tables(database: nil))
    }

    @Test func nothingInsideStringsOrComments() {
        #expect(at("SELECT 'FROM ord") == .none)
        #expect(at("SELECT 1 -- FROM ord") == .none)
        #expect(at("SELECT 'a' FROM ord") == .tables(database: nil))
    }

    @Test func listForTablePrefix() throws {
        let sql = "SELECT * FROM ord"
        let list = try #require(SQLCompletion.complete(sql, cursor: 17, catalog: catalog))
        #expect(list.items.map(\.name) == ["order_items", "orders", "order_totals"])
        #expect(list.replaceRange == NSRange(location: 14, length: 3))
        #expect(list.items.last?.kind == .view)
        #expect(list.items.first?.insertText == "order_items ")
    }

    @Test func columnsInScopeComeFirst() throws {
        let sql = "SELECT to FROM orders"
        let list = try #require(SQLCompletion.complete(sql, cursor: 9, catalog: catalog))
        #expect(list.items.first == Completion(kind: .column, name: "total", detail: "decimal(10,2) · orders", insertText: "total"))
    }

    @Test func keywordsAddASpaceColumnsDoNot() throws {
        let keyword = try #require(SQLCompletion.complete("SEL", cursor: 3, catalog: catalog))
        #expect(keyword.items.first == Completion(kind: .keyword, name: "SELECT", detail: "keyword", insertText: "SELECT "))
        let column = try #require(SQLCompletion.complete("SELECT c.na FROM customers c", cursor: 11, catalog: catalog))
        #expect(column.items.first?.insertText == "name")
        let database = try #require(SQLCompletion.complete("SELECT * FROM quarry_l", cursor: 22, catalog: catalog))
        #expect(database.items.first?.insertText == "quarry_legacy")
    }

    @Test func emptyWordOnlyAfterDotOrWhenAsked() {
        #expect(SQLCompletion.complete("SELECT ", cursor: 7, catalog: catalog) == nil)
        #expect(SQLCompletion.complete("SELECT ", cursor: 7, catalog: catalog, explicit: true)?.items.isEmpty == false)
        let sql = "SELECT c. FROM customers c"
        #expect(SQLCompletion.complete(sql, cursor: 9, catalog: catalog)?.items.map(\.name) == ["id", "name"])
    }

    @Test func aCompleteWordShowsNothing() {
        #expect(SQLCompletion.complete("SELECT * FROM order_totals", cursor: 26, catalog: catalog) == nil)
    }

    @Test func unloadedDatabaseIsRequested() {
        let list = SQLCompletion.complete("SELECT * FROM quarry_legacy.", cursor: 28, catalog: catalog)
        #expect(list?.needsDatabase == "quarry_legacy")
    }

    @Test func aliasesAreRead() {
        let refs = SQLCompletion.tableReferences(in: "SELECT * FROM customers c LEFT JOIN quarry_demo.orders AS o ON o.customer_id = c.id, products")
        #expect(refs == [
            .init(database: nil, table: "customers", alias: "c"),
            .init(database: "quarry_demo", table: "orders", alias: "o"),
        ])
        let list = SQLCompletion.tableReferences(in: "SELECT * FROM a x, `b c` y WHERE 1")
        #expect(list.map(\.table) == ["a", "b c"])
        #expect(list.map(\.alias) == ["x", "y"])
    }

    @Test func namesAreQuotedWhenNeeded() {
        #expect(SQLCompletion.quoted("orders") == "orders")
        #expect(SQLCompletion.quoted("order items") == "`order items`")
        #expect(SQLCompletion.quoted("select") == "`select`")
        #expect(SQLCompletion.quoted("2024_data") == "`2024_data`")
    }
}
