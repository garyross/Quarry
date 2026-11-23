import AppKit
import QuarryKit

/// S-069: editing rows in a SQLite file, on the tab `sqliteFiles` opened on the fixture.
extension SelfTest {
    static func sqliteEditing(_ tab: Session) async {
        let content = tab.content
        tab.view = .content
        tab.selectedObjectID = "table:customers"
        await tab.currentLoad?.value
        await until { content.grid.rows.count == 6 }
        let (id, name, email, country, created) = (column(in: content.grid, "id"), column(in: content.grid, "name"),
                                                    column(in: content.grid, "email"), column(in: content.grid, "country"),
                                                    column(in: content.grid, "created_at"))
        check("S-069 a SQLite table's key comes from the file", content.columns.first?.isPrimaryKey == true && content.rowIDName == nil)

        // Inline edit, then a refused one (email is UNIQUE), then Set to NULL.
        let row = content.grid.rows.firstIndex { $0[name] == .text("Grace Hopper") } ?? 1
        tab.editContent(row: row, column: name, to: .text("Grace B. Hopper"))
        await tab.currentLoad?.value
        check("S-069 an inline edit saves to the file",
              await firstValue(in: tab, "SELECT name FROM customers WHERE email = 'grace@example.com'") == "Grace B. Hopper"
                  && content.editError == nil, content.editError?.message ?? "")
        let before = content.grid.rows[row][email]
        tab.editContent(row: row, column: email, to: .text("ada@example.com"))
        await tab.currentLoad?.value
        check("S-069 a constraint error shows SQLite's message and puts the value back",
              content.editError?.message.contains("UNIQUE constraint failed") == true && content.grid.rows[row][email] == before,
              content.editError?.message ?? "no error")
        content.editError = nil
        tab.editContent(row: row, column: email, to: .null)
        await tab.currentLoad?.value
        check("S-069 Set to NULL saves NULL",
              await firstValue(in: tab, "SELECT COALESCE(email, 'null') FROM customers WHERE name = 'Grace B. Hopper'") == "null")
        tab.editContent(row: row, column: email, to: before)
        await tab.currentLoad?.value

        // Add Row: defaults without quotes, the rowid left to SQLite.
        tab.addRow()
        await tab.currentLoad?.value
        guard let draft = content.draft else {
            check("S-069 Add Row starts a new row", false, content.editError?.message ?? "")
            return
        }
        let fresh = content.grid.rows[draft.row]
        check("S-069 a new row starts with the file's defaults",
              fresh[id] == .null && fresh[country] == .text("US") && fresh[created] == .text("CURRENT_TIMESTAMP")
                  && content.editRequest?.column == name, "\(fresh)")
        tab.editContent(row: draft.row, column: name, to: .text("Self-Test Row"))
        tab.endRowEdit(row: draft.row, cancelled: false)
        await tab.currentLoad?.value
        let newID = await firstValue(in: tab, "SELECT MAX(id) FROM customers WHERE name = 'Self-Test Row'")
        check("S-069 Add Row inserts, and the new rowid fills in",
              newID != nil && content.grid.rows.contains { $0[id] == .text(newID!) && $0[country] == .text("US") }
                  && content.draft == nil && content.editError == nil, content.editError?.message ?? "")
        if let added = content.grid.rows.firstIndex(where: { $0[name] == .text("Self-Test Row") }) {
            content.selection = [added]
            tab.duplicateRow()
            await tab.currentLoad?.value
            if let copy = content.draft?.row { tab.endRowEdit(row: copy, cancelled: false) }
            await tab.currentLoad?.value
        }
        check("S-069 Duplicate Row copies the row with a new id",
              await firstValue(in: tab, "SELECT COUNT(DISTINCT id) FROM customers WHERE name = 'Self-Test Row'") == "2",
              content.editError?.message ?? "")

        // Copy as SQL INSERT on the selected rows.
        let copies = IndexSet(content.grid.rows.indices.filter { content.grid.rows[$0][name] == .text("Self-Test Row") })
        let coordinator = DataGrid.Coordinator()
        let scroll = DataGrid.makeScrollView(coordinator: coordinator, accessibilityLabel: "Self-test")
        coordinator.data = content.grid
        coordinator.insertTable = DataGrid.InsertTarget(table: "customers", engine: .sqlite)
        coordinator.rebuildColumns()
        coordinator.table?.reloadData()
        scroll.layoutSubtreeIfNeeded()
        coordinator.table?.selectRowIndexes(copies, byExtendingSelection: false)
        let insert = coordinator.copyText(.insert) ?? ""
        check("S-069 Copy as SQL INSERT holds the selected rows",
              insert.hasPrefix("INSERT INTO `customers` (`id`, `name`") && insert.components(separatedBy: "'Self-Test Row'").count == 3,
              insert)

        content.selection = copies
        tab.deleteRows()
        tab.confirmDeleteRows()
        await tab.currentLoad?.value
        check("S-069 Delete removes the rows from the file",
              await firstValue(in: tab, "SELECT COUNT(*) FROM customers WHERE name = 'Self-Test Row'") == "0"
                  && content.grid.rows.count == 6 && content.editError == nil, content.editError?.message ?? "")

        await sqliteFieldEditor(tab)
        await sqliteKeylessRows(tab)
        await sqliteLinks(tab)
        await sqliteResultEdits(tab)
    }

    /// The Field Editor on a TEXT and a BLOB cell; a BLOB saves as X'…'.
    static func sqliteFieldEditor(_ tab: Session) async {
        let content = tab.content
        tab.selectedObjectID = "table:products"
        await tab.currentLoad?.value
        await until { content.grid.rows.count == 4 }
        let (title, photo) = (column(in: content.grid, "title"), column(in: content.grid, "photo"))
        tab.openFieldEditor(row: 0, column: photo)
        guard let blob = tab.fieldEditor else {
            check("S-069 a BLOB opens in the Field Editor", false)
            return
        }
        check("S-069 a BLOB opens in Hex", blob.mode == .hex && blob.isEditable && blob.hexDump.hasPrefix("00000000  89 50 4E 47"),
              blob.hexDump)
        tab.fieldEditor = nil
        tab.saveFieldEditor(row: 1, column: photo, value: .binary(Data([0xCA, 0xFE])))
        await tab.currentLoad?.value
        check("S-069 the Field Editor saves bytes as a BLOB",
              await firstValue(in: tab, "SELECT typeof(photo) || ':' || hex(photo) FROM products WHERE id = 2") == "blob:CAFE",
              content.editError?.message ?? "")
        tab.saveFieldEditor(row: 1, column: photo, value: .null)
        await tab.currentLoad?.value
        tab.openFieldEditor(row: 2, column: title)
        tab.fieldEditor?.text = "27-inch Studio Display"
        tab.fieldEditor?.save()
        await tab.currentLoad?.value
        check("S-069 the Field Editor saves text",
              await firstValue(in: tab, "SELECT title FROM products WHERE id = 3") == "27-inch Studio Display",
              content.editError?.message ?? "")
        // The trigger refuses negative stock; its message shows.
        let stock = column(in: content.grid, "stock")
        tab.editContent(row: 0, column: stock, to: .text("-1"))
        await tab.currentLoad?.value
        check("S-069 a trigger's RAISE shows as the edit's error", content.editError?.message == "stock can't go below zero",
              content.editError?.message ?? "no error")
        content.editError = nil
    }

    /// notes has no primary key (found by rowid); settings is WITHOUT ROWID; a view is read only.
    static func sqliteKeylessRows(_ tab: Session) async {
        let content = tab.content
        tab.selectedObjectID = "table:notes"
        await tab.currentLoad?.value
        await until { content.grid.rows.count == 1 }
        check("S-069 a table with no primary key is found by rowid, which the grid doesn't show",
              content.rowIDName == "rowid" && content.rowIDs == [.text("1")] && content.grid.columns.map(\.title) == ["body"],
              "\(content.rowIDName ?? "none") \(content.grid.columns.map(\.title))")
        tab.editContent(row: 0, column: 0, to: .text("Edited by rowid"))
        await tab.currentLoad?.value
        check("S-069 an edit on a table with no key saves by rowid",
              await firstValue(in: tab, "SELECT body FROM notes WHERE rowid = 1") == "Edited by rowid" && content.editError == nil,
              content.editError?.message ?? "")
        tab.addRow()
        await tab.currentLoad?.value
        if let row = content.draft?.row {
            tab.editContent(row: row, column: 0, to: .text("Second note"))
            tab.endRowEdit(row: row, cancelled: false)
            await tab.currentLoad?.value
        }
        check("S-069 Add Row on a table with no key", content.grid.rows.count == 2 && content.rowIDs.count == 2,
              content.editError?.message ?? "\(content.grid.rows.count)")
        content.selection = [1]
        tab.deleteRows()
        tab.confirmDeleteRows()
        await tab.currentLoad?.value
        check("S-069 Delete on a table with no key removes only that row",
              await firstValue(in: tab, "SELECT COUNT(*) FROM notes") == "1" && content.grid.rows.count == 1,
              content.editError?.message ?? "")
        tab.view = .info
        await tab.currentLoad?.value
        check("S-069 Info says rows are found by rowid", tab.info.rowNote == "Rows are found by rowid (no primary key).")
        tab.view = .content
        await tab.currentLoad?.value

        tab.selectedObjectID = "table:settings"
        await tab.currentLoad?.value
        await until { content.grid.rows.count == 2 }
        let (value, revision) = (column(in: content.grid, "value"), column(in: content.grid, "revision"))
        check("S-069 a WITHOUT ROWID table is found by its primary key", content.rowIDName == nil && content.columns.first?.isPrimaryKey == true)
        let theme = content.grid.rows.firstIndex { $0.first == .text("theme") } ?? 0
        tab.editContent(row: theme, column: value, to: .text("light"))
        await tab.currentLoad?.value
        check("S-069 an edit on a WITHOUT ROWID table saves",
              await firstValue(in: tab, "SELECT value FROM settings WHERE key = 'theme'") == "light" && content.editError == nil,
              content.editError?.message ?? "")
        let locale = content.grid.rows.firstIndex { $0.first == .text("locale") } ?? 0
        let note = content.grid.columns[revision].affinity?.storedNote(content.grid.rows[locale][revision])
        check("S-069 TEXT in an INTEGER column shows as stored, with a tooltip",
              content.grid.rows[locale][revision] == .text("draft") && note == "Stored as TEXT", note ?? "none")

        tab.selectedObjectID = "view:order_totals"
        await tab.currentLoad?.value
        await until { !content.grid.rows.isEmpty }
        check("S-069 a view stays read only, and says why",
              !content.canEdit(row: 0, column: 0) && !content.canAddRow && !content.isTable
                  && content.grid.columns.first?.help == "Views in SQLite can’t be edited.",
              content.grid.columns.first?.help ?? "no help")
    }

    /// ⌘↓ follows order_items.order_id to orders; Back and Forward.
    static func sqliteLinks(_ tab: Session) async {
        let content = tab.content
        tab.history.removeAll()
        check("S-069 foreign keys are on for Quarry's connection", await firstValue(in: tab, "PRAGMA foreign_keys") == "1")
        tab.selectedObjectID = "table:order_items"
        await tab.currentLoad?.value
        await until { content.grid.rows.count == 7 }
        let orderID = column(in: content.grid, "order_id")
        let target = content.grid.rows[0][orderID].plainText ?? ""
        await tab.followLink(row: 0, column: orderID)?.value
        check("S-069 following order_id opens orders filtered to that id",
              tab.selectedObjectID == "table:orders" && content.grid.rows.count == 1 && content.grid.rows.first?.first?.plainText == target,
              "\(tab.selectedObjectID ?? "nil") \(content.filter.appliedClause ?? "no filter") \(content.load.error?.message ?? "")")
        await tab.goBack()?.value
        check("S-069 Back returns to order_items", tab.selectedObjectID == "table:order_items" && !content.isFiltered)
        await tab.goForward()?.value
        check("S-069 Forward opens the order again", tab.selectedObjectID == "table:orders" && content.grid.rows.count == 1)
        await tab.goBack()?.value
        tab.history.removeAll()
    }

    /// A query result with its table's key edits on SQLite too (S-035).
    static func sqliteResultEdits(_ tab: Session) async {
        tab.view = .query
        tab.query.text = "SELECT id, name, length(name) AS size FROM customers WHERE id = 1"
        tab.runAll()
        await tab.currentLoad?.value
        check("S-069 a SQLite result with its key is editable",
              tab.canEditQueryCell(row: 0, column: 1) && !tab.canEditQueryCell(row: 0, column: 2),
              tab.query.results.columns.map { $0.help ?? "-" }.joined(separator: " | "))
        tab.editQueryCell(row: 0, column: 1, to: .text("Ada King"))
        await tab.currentLoad?.value
        check("S-069 editing a SQLite result cell saves it",
              await firstValue(in: tab, "SELECT name FROM customers WHERE id = 1") == "Ada King"
                  && tab.query.results.rows.first?[1] == .text("Ada King") && tab.query.editError == nil,
              tab.query.editError?.message ?? "")
        tab.editQueryCell(row: 0, column: 1, to: .text("Ada Lovelace"))
        await tab.currentLoad?.value
        tab.query.text = ""
        tab.view = .content
        await tab.currentLoad?.value
    }
}
