import Foundation
import Testing
import QuarryKit
import QuarryControllers

/// Content (S-005, S-009, S-010, S-069) through ContentController's interface,
/// on a copy of the SQLite fixture: no window, no server.
@Suite struct ContentControllerTests {
    /// A controller showing `table` of a fresh fixture file.
    static func showing(_ table: String, pageSize: Int = 1000, readOnly: Bool = false)
        async throws -> (ContentController, DatabaseClient) {
        let client = try await Fixture.sqlite(readOnly: readOnly)
        let content = ContentController(pageSize: { pageSize })
        let object = try await Fixture.object(table, client: client)
        await content.show(object, in: "main", client: client, force: false)?.value
        #expect(content.load.error == nil)
        return (content, client)
    }

    static func column(_ name: String, _ content: ContentController) throws -> Int {
        try #require(content.columns.firstIndex { $0.name == name })
    }

    @Test func showsATablesRowsAndColumns() async throws {
        let (content, _) = try await Self.showing("customers")
        #expect(content.grid.columns.map(\.title) == ["id", "name", "email", "country", "created_at"])
        #expect(content.grid.rows.count == 6)
        #expect(content.paging.total == 6)
        #expect(content.grid.rows[0][1] == .text("Ada Lovelace"))
        #expect(content.isTable && !content.findsRowsByRowID)
    }

    @Test func pagesByTheGivenPageSize() async throws {
        let (content, _) = try await Self.showing("events", pageSize: 1000)
        #expect(content.paging.pageSize == 1000)
        #expect(content.paging.total == 2500)
        #expect(content.grid.rows.count == 1000)
        await content.move(by: 2)?.value
        #expect(content.paging.page == 2)
        #expect(content.grid.rows.count == 500)
        #expect(content.grid.rows[0][0] == .text("2001"))
    }

    @Test func sortsOnTheServer() async throws {
        let (content, _) = try await Self.showing("customers")
        await content.sort(by: "name", ascending: false)?.value
        #expect(content.sortColumn == "name" && !content.ascending)
        #expect(content.grid.rows.first?[1] == .text("Margaret Hamilton"))
    }

    @Test func anEditedCellIsSavedAndReadBack() async throws {
        let (content, client) = try await Self.showing("customers")
        let country = try Self.column("country", content)
        #expect(content.canEdit(row: 0, column: country))
        await content.edit(row: 0, column: country, to: .text("NZ"))?.value
        #expect(content.editError == nil)
        #expect(content.grid.rows[0][country] == .text("NZ"))
        #expect(try await Fixture.strings("SELECT country FROM customers WHERE id = 1", client: client) == ["NZ"])
    }

    @Test func anEditWithTheSameTextChangesNothing() async throws {
        let (content, _) = try await Self.showing("customers")
        let country = try Self.column("country", content)
        #expect(content.edit(row: 0, column: country, to: .text("UK")) == nil)
    }

    @Test func setToNullSavesNull() async throws {
        let (content, client) = try await Self.showing("customers")
        let email = try Self.column("email", content)
        await content.edit(row: 0, column: email, to: .null)?.value
        #expect(content.grid.rows[0][email].isNull)
        #expect(try await Fixture.strings("SELECT email FROM customers WHERE id = 1", client: client) == [nil])
    }

    @Test func aNewRowIsInsertedWithTheServersValues() async throws {
        let (content, client) = try await Self.showing("customers")
        #expect(content.canAddRow)
        await content.addRow()?.value
        let row = try #require(content.draft?.row)
        #expect(row == 6 && content.selection == [6])
        content.edit(row: row, column: try Self.column("name", content), to: .text("Edsger Dijkstra"))
        await content.endRowEdit(row: row, cancelled: false)?.value
        #expect(content.draft == nil && content.editError == nil)
        #expect(content.paging.total == 7)
        // The new id and the defaults come back from the file.
        #expect(content.grid.rows[row][0] == .text("7"))
        #expect(content.grid.rows[row][try Self.column("country", content)] == .text("US"))
        #expect(try await Fixture.strings("SELECT name FROM customers WHERE id = 7", client: client) == ["Edsger Dijkstra"])
    }

    @Test func escapeRemovesANewRow() async throws {
        let (content, _) = try await Self.showing("customers")
        await content.addRow()?.value
        let row = try #require(content.draft?.row)
        #expect(content.endRowEdit(row: row, cancelled: true) == nil)
        #expect(content.draft == nil && content.grid.rows.count == 6)
    }

    @Test func duplicateCopiesTheRowButNotItsKey() async throws {
        let (content, _) = try await Self.showing("customers")
        content.selection = [1]
        #expect(content.canDuplicateRow)
        await content.addRow(copying: 1)?.value
        let row = try #require(content.draft?.row)
        let name = try Self.column("name", content)
        #expect(content.grid.rows[row][name] == .text("Grace Hopper"))
        #expect(content.draft?.setColumns.contains(0) == false)
    }

    @Test func deleteAsksThenDeletesTheSelectedRows() async throws {
        let (content, client) = try await Self.showing("customers")
        // Alan and Linus have no orders.
        content.selection = [2, 4]
        #expect(content.canDeleteRows)
        content.requestDelete()
        #expect(content.pendingDelete == [2, 4])
        await content.confirmDelete()?.value
        #expect(content.editError == nil)
        #expect(content.grid.rows.count == 4)
        #expect(try await Fixture.strings("SELECT COUNT(*) FROM customers", client: client) == ["4"])
    }

    @Test func aDeleteTheFileRefusesSaysWhyAndKeepsTheRows() async throws {
        let (content, client) = try await Self.showing("customers")
        // Katherine's order has items, which don't cascade.
        content.selection = [5]
        content.requestDelete()
        await content.confirmDelete()?.value
        #expect(content.editError?.message.contains("FOREIGN KEY") == true)
        #expect(content.grid.rows.count == 6)
        #expect(try await Fixture.strings("SELECT COUNT(*) FROM customers", client: client) == ["6"])
    }

    @Test func aTableWithNoPrimaryKeyIsEditedByRowID() async throws {
        let (content, client) = try await Self.showing("notes")
        #expect(content.findsRowsByRowID)
        #expect(content.rowIDs.count == 1)
        await content.edit(row: 0, column: 0, to: .text("Edited by rowid"))?.value
        #expect(content.editError == nil)
        #expect(try await Fixture.strings("SELECT body FROM notes", client: client) == ["Edited by rowid"])
    }

    @Test func aWithoutRowIDTableIsEditedByItsKey() async throws {
        let (content, client) = try await Self.showing("settings")
        #expect(!content.findsRowsByRowID)
        let value = try Self.column("value", content)
        let theme = try #require(content.grid.rows.firstIndex { $0[0] == .text("theme") })
        await content.edit(row: theme, column: value, to: .text("light"))?.value
        #expect(try await Fixture.strings("SELECT value FROM settings WHERE key = 'theme'", client: client) == ["light"])
    }

    @Test func aReadOnlyFileOffersNoChanges() async throws {
        let (content, _) = try await Self.showing("customers", readOnly: true)
        content.selection = [0]
        #expect(!content.canAddRow)
        #expect(!content.canDeleteRows)
        #expect(!content.canChange(row: 0, column: 1))
        #expect(content.edit(row: 0, column: 1, to: .text("x")) == nil)
        #expect(content.addRow() == nil)
    }

    @Test func aViewShowsRowsButIsNotATable() async throws {
        let (content, _) = try await Self.showing("order_totals")
        #expect(!content.isTable)
        #expect(content.grid.rows.count == 5)
        #expect(!content.canAddRow)
        #expect(!content.canChange(row: 0, column: 0))
    }

    @Test func filterRulesNarrowThePage() async throws {
        let (content, _) = try await Self.showing("customers")
        content.filter.draft = FilterTree(RowFilter(column: "country", value: "UK"))
        await content.filter.apply()?.value
        #expect(content.isFiltered)
        #expect(content.filter.appliedClause == "`country` = 'UK'")
        #expect(content.grid.rows.count == 2)
        #expect(content.paging.total == 2)
        #expect(content.unfilteredTotal == 6)
        await content.filter.clear()?.value
        #expect(!content.isFiltered)
        #expect(content.grid.rows.count == 6)
    }

    @Test func aFilterValueWithAQuoteIsQuotedForSQLite() async throws {
        let (content, client) = try await Self.showing("customers")
        _ = try await client.run("UPDATE customers SET name = 'O''Brien\\x' WHERE id = 2")
        content.filter.draft = FilterTree(RowFilter(column: "name", value: "O'Brien\\x"))
        await content.filter.apply()?.value
        #expect(content.load.error == nil)
        #expect(content.grid.rows.count == 1)
    }

    @Test func backRestoresSortFilterAndPage() async throws {
        let (content, client) = try await Self.showing("events", pageSize: 1000)
        await content.sort(by: "id", ascending: false)?.value
        await content.move(by: 1)?.value
        let saved = try #require(content.saved)
        let customers = try await Fixture.object("customers", client: client)
        await content.show(customers, in: "main", client: client, force: false)?.value
        #expect(content.sortColumn == nil)
        content.pendingRestore = saved
        let events = try await Fixture.object("events", client: client)
        await content.show(events, in: "main", client: client, force: false)?.value
        #expect(content.sortColumn == "id" && !content.ascending)
        #expect(content.paging.page == 1)
        #expect(content.grid.rows.first?[0] == .text("1500"))
    }
}
