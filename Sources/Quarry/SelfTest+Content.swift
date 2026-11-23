import AppKit
import QuarryKit
import SwiftData

/// Self-test: Content: inline edits, editors, rows, filters, saved filters, foreign-key links and copying (S-009 to S-017, S-061, S-062).
extension SelfTest {
    // MARK: S-009

    static func editing(session: Session) async {
        session.database = "quarry_demo"
        await session.currentLoad?.value
        session.view = .content
        session.selectedObjectID = "table:customers"
        await session.currentLoad?.value
        let content = session.content
        guard let name = content.grid.columns.firstIndex(where: { $0.title == "name" }),
              let email = content.grid.columns.firstIndex(where: { $0.title == "email" }),
              content.grid.rows.count == 10 else {
            check("S-009 customers is open for editing", false)
            return
        }

        // Row 4 is Katherine Johnson (id 4).
        session.editContent(row: 3, column: name, to: .text("Katherine G. Johnson"))
        await session.currentLoad?.value
        check("S-009 an edit is saved on the server",
              await firstValue(in: session, "SELECT name FROM quarry_demo.customers WHERE id = 4") == "Katherine G. Johnson")
        check("S-009 the page reloads with the saved value",
              content.grid.rows[3][name] == .text("Katherine G. Johnson") && content.editError == nil,
              content.editError?.message ?? "")
        session.editContent(row: 3, column: name, to: .text("Katherine Johnson"))
        await session.currentLoad?.value

        // ada@example.com belongs to row 1, and email is unique.
        let before = content.grid.rows[1][email]
        session.editContent(row: 1, column: email, to: .text("ada@example.com"))
        await session.currentLoad?.value
        check("S-009 a failed update shows the server's error", content.editError?.code == 1062,
              content.editError?.message ?? "no error")
        check("S-009 and puts the old value back", content.grid.rows[1][email] == before)
        check("S-009 the server kept the old value",
              await firstValue(in: session, "SELECT email FROM quarry_demo.customers WHERE id = 2") == before.plainText)
        content.editError = nil

        // The grid itself, off screen: Escape cancels, Return saves.
        let coordinator = DataGrid.Coordinator()
        let scroll = DataGrid.makeScrollView(coordinator: coordinator, accessibilityLabel: "Self-test")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        var saved: [CellValue] = []
        var ended: [Bool] = []
        coordinator.editing = DataGrid.Editing(canEdit: content.canEdit, text: content.editingText,
                                               save: { _, _, value in saved.append(value) },
                                               endRow: { _, cancelled in ended.append(cancelled) })
        coordinator.data = content.grid
        coordinator.rebuildColumns()
        coordinator.table?.reloadData()
        scroll.layoutSubtreeIfNeeded()
        func type(_ text: String, then command: Selector) {
            guard coordinator.beginEditing(row: 0, column: name),
                  let editor = window.firstResponder as? NSTextView else { return }
            editor.string = text
            editor.didChangeText()
            editor.doCommand(by: command)
        }
        type("Changed", then: #selector(NSResponder.cancelOperation(_:)))
        let shown = (coordinator.table?.view(atColumn: name, row: 0, makeIfNecessary: false) as? GridCellView)?.shownText
        check("S-009 Escape cancels the edit", saved.isEmpty && shown == content.grid.rows[0][name].displayText,
              "saved \(saved), shows \(shown ?? "nil")")
        type("Ada King", then: #selector(NSResponder.insertNewline(_:)))
        check("S-009 Return saves the edit", saved == [.text("Ada King")], "\(saved)")
        // S-010: a new row is saved when editing leaves the row, so Tab must not end it.
        ended = []
        if coordinator.beginEditing(row: 0, column: name), let editor = window.firstResponder as? NSTextView {
            editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        }
        let stillEditing = window.firstResponder is NSTextView
        window.makeFirstResponder(coordinator.table)
        check("S-010 Tab moves along the row without ending it, leaving does",
              stillEditing && ended == [false], "editing \(stillEditing), ended \(ended)")

        // S-011: Set to NULL (⌃⇧N) while editing saves NULL, even after typing "NULL".
        let notes = content.grid.columns.firstIndex { $0.title == "notes" } ?? 0
        saved = []
        if coordinator.beginEditing(row: 0, column: notes), let editor = window.firstResponder as? NSTextView {
            editor.string = "NULL"
            editor.didChangeText()
            // As the menu does: up the responder chain from the editor to the table.
            _ = editor.tryToPerform(#selector(GridCopying.setCellToNull(_:)), with: nil)
        }
        check("S-011 Set to NULL ends the edit with NULL", saved == [.null] && !coordinator.isEditingCell, "\(saved)")
        window.close()

        let rowID = content.grid.rows[0][content.grid.columns.firstIndex { $0.title == "id" } ?? 0].plainText ?? ""
        let originalNotes = content.grid.rows[0][notes]
        session.editContent(row: 0, column: notes, to: .text("NULL"))
        await session.currentLoad?.value
        check("S-011 typing NULL saves the text", await firstValue(in: session, "SELECT notes FROM quarry_demo.customers WHERE id = \(rowID)") == "NULL")
        session.editContent(row: 0, column: notes, to: .null)
        await session.currentLoad?.value
        check("S-011 Set to NULL saves NULL, not the text",
              await firstValue(in: session, "SELECT notes IS NULL FROM quarry_demo.customers WHERE id = \(rowID)") == "1"
                  && content.grid.rows[0][notes] == .null, content.editError?.message ?? "")
        session.editContent(row: 0, column: notes, to: originalNotes)  // Leave the fixture as it was.
        await session.currentLoad?.value
    }

    // MARK: S-012

    static func fieldEditing(session: Session) async {
        session.view = .content
        session.selectedObjectID = "table:products"
        await session.currentLoad?.value
        let content = session.content
        let (sku, attributes, thumbnail) = (column(in: content.grid, "sku"), column(in: content.grid, "attributes"), column(in: content.grid, "thumbnail"))
        guard content.grid.rows.count == 5 else {
            check("S-012 products is open", false, "\(content.grid.rows.count) rows")
            return
        }
        check("S-012 JSON and BLOB cells open the Field Editor, short text stays inline",
              content.opensFieldEditor(row: 0, column: attributes) && content.opensFieldEditor(row: 0, column: thumbnail)
                  && !content.opensFieldEditor(row: 0, column: sku) && content.canEdit(row: 0, column: sku)
                  && !content.canEdit(row: 0, column: attributes))

        // Open in Field Editor from the grid: the row's first long value.
        let coordinator = DataGrid.Coordinator()
        let scroll = DataGrid.makeScrollView(coordinator: coordinator, accessibilityLabel: "Self-test")
        var opened: [Int] = []
        coordinator.fieldEditor = DataGrid.FieldEditorHook(opens: content.opensFieldEditor, open: { _, column, _ in opened.append(column) })
        coordinator.data = content.grid
        coordinator.rebuildColumns()
        coordinator.table?.reloadData()
        scroll.layoutSubtreeIfNeeded()
        coordinator.table?.selectRowIndexes([0], byExtendingSelection: false)
        coordinator.openFieldEditor()
        // flags is BIT(8): it comes before attributes and opens in the Bit Editor (S-013).
        check("S-012 Open in Field Editor picks the row's first long value", opened == [column(in: content.grid, "flags")], "\(opened)")

        // JSON: pretty-printed, an untouched value saves nothing, invalid JSON blocks Save.
        session.openFieldEditor(row: 0, column: attributes)
        guard let json = session.fieldEditor else {
            check("S-012 the Field Editor opens", false)
            return
        }
        check("S-012 JSON opens pretty-printed in Text",
              json.isJSON && json.mode == .text && json.text == "{\n  \"color\": \"white\",\n  \"volume_ml\": 350\n}",
              json.text)
        check("S-012 an untouched value has nothing to save", !json.canSave && json.value == content.grid.rows[0][attributes])
        json.text = "{\n  \"color\": \"blue\",\n  \"volume_ml\": 350,\n}"
        check("S-012 invalid JSON is flagged before save", json.jsonProblem != nil && !json.canSave,
              json.jsonProblem?.description ?? "no problem")
        json.text = "{\n  \"color\": \"blue\",\n  \"volume_ml\": 350\n}"
        json.save()
        await session.currentLoad?.value
        check("S-012 Save writes the JSON compact again, as it was",
              await firstValue(in: session, "SELECT attributes FROM quarry_demo.products WHERE id = 1") == #"{"color":"blue","volume_ml":350}"#
                  && session.fieldEditor == nil, content.editError?.message ?? "")
        session.editContent(row: 0, column: attributes, to: .text(#"{"color":"white","volume_ml":350}"#))
        await session.currentLoad?.value

        // A picture opens in Image; Save to File… writes it, Open File… loads it into another cell.
        session.openFieldEditor(row: 4, column: thumbnail)
        guard let picture = session.fieldEditor else { return }
        check("S-012 an image BLOB previews in Image mode",
              picture.mode == .image && picture.image != nil && picture.modes == [.image, .hex], "\(picture.modes)")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("quarry-selftest-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        picture.write(to: file)
        check("S-012 Save to File… writes the value's bytes",
              (try? Data(contentsOf: file)) == picture.data && picture.data.count == 934 && picture.fileError == nil)
        session.fieldEditor = nil

        let originalThumb = content.grid.rows[0][thumbnail]
        session.openFieldEditor(row: 0, column: thumbnail)
        guard let blob = session.fieldEditor else { return }
        check("S-012 bytes that are not text or a picture open in Hex",
              blob.mode == .hex && blob.modes == [.hex] && blob.hexDump.hasPrefix("00000000  89 50 4E 47"), blob.hexDump)
        blob.load(from: file)
        check("S-012 Open File… loads a file into the value", blob.mode == .image && blob.canSave && blob.data.count == 934)
        blob.save()
        await session.currentLoad?.value
        check("S-012 the loaded file is saved to the cell",
              await firstValue(in: session, "SELECT LENGTH(thumbnail) FROM quarry_demo.products WHERE id = 1") == "934",
              content.editError?.message ?? "")
        session.editContent(row: 0, column: thumbnail, to: originalThumb)  // Leave the fixture as it was.
        await session.currentLoad?.value
        check("S-012 the fixture's BLOB is back", content.grid.rows[0][thumbnail] == originalThumb)
    }

    // MARK: S-013

    /// The Bit Editor on products.flags, BIT(8): MUG-01 is b'00000101'.
    static func bitEditor(session: Session) async {
        let content = session.content
        let flags = content.grid.columns.firstIndex { $0.title == "flags" } ?? 0
        let flagsSQL = "SELECT BIN(flags) FROM quarry_demo.products WHERE id = 1"
        check("S-013 a BIT column knows its width", content.bitWidth(column: flags) == 8 && content.grid.columns[flags].bitWidth == 8)
        session.openFieldEditor(row: 0, column: flags)
        guard let editor = session.bitEditor else {
            check("S-013 a BIT cell opens the Bit Editor", false, session.fieldEditor == nil ? "nothing opened" : "Field Editor opened")
            return
        }
        check("S-013 a BIT cell opens the Bit Editor, not the Field Editor",
              session.fieldEditor == nil && editor.width == 8 && editor.bits.bits == "00000101"
                  && editor.text(.hexadecimal) == "5" && editor.text(.decimal) == "5" && editor.text(.octal) == "5"
                  && !editor.canSave && !editor.isNullable)
        editor.toggle(7)
        check("S-013 toggling a bit updates every base",
              editor.text(.decimal) == "133" && editor.text(.hexadecimal) == "85" && editor.text(.octal) == "205")
        editor.type("300", in: .decimal)
        check("S-013 a number too big for BIT(8) is flagged and blocks Save",
              editor.problems[.decimal] != nil && !editor.canSave && editor.bits.raw == 133)
        editor.type("A2", in: .hexadecimal)
        check("S-013 typing hex sets the bits and clears the problem",
              editor.problems.isEmpty && editor.bits.bits == "10100010" && editor.text(.decimal) == "162" && editor.canSave)
        editor.shiftRight()
        editor.rotateRight()
        check("S-013 shift and rotate", editor.bits.bits == "10101000", editor.bits.bits)
        editor.save()
        await session.currentLoad?.value
        let saved = await firstValue(in: session, flagsSQL)
        check("S-013 Save writes the bits to the server",
              saved == "10101000" && session.bitEditor == nil && content.editError == nil,
              content.editError?.message ?? (saved ?? "nil"))
        check("S-013 the grid shows BIT values as bits", BitValue(width: 8, value: content.grid.rows[0][flags]).bits == "10101000")
        session.editContent(row: 0, column: flags, to: .binary(Data([5])))  // Leave the fixture as it was.
        await session.currentLoad?.value
        let restored = await firstValue(in: session, flagsSQL)
        check("S-013 the fixture's flags are back", restored == "101")
    }

    // MARK: S-010

    static func rows(session: Session) async {
        session.view = .content
        session.selectedObjectID = "table:customers"
        await session.currentLoad?.value
        let content = session.content
        let (id, name, country, created) = (column(in: content.grid, "id"), column(in: content.grid, "name"), column(in: content.grid, "country"), column(in: content.grid, "created_at"))
        let start = content.grid.rows.count

        session.addRow()
        await session.currentLoad?.value
        guard let draft = content.draft else {
            check("S-010 Add Row starts a new row", false, content.editError?.message ?? "")
            return
        }
        let fresh = content.grid.rows[draft.row]
        check("S-010 a new row starts with default values",
              fresh[id] == .null && fresh[country] == .text("US") && fresh[created] == .text("current_timestamp()")
              && content.editRequest?.column == name, "\(fresh)")
        session.endRowEdit(row: draft.row, cancelled: true)
        check("S-010 Escape removes the unsaved row", content.draft == nil && content.grid.rows.count == start)

        // Add, then duplicate it twice: three rows to delete.
        var added: [Int] = []
        session.addRow()
        await session.currentLoad?.value
        if let row = content.draft?.row {
            session.editContent(row: row, column: name, to: .text("Self-Test Row"))
            session.endRowEdit(row: row, cancelled: false)
            await session.currentLoad?.value
            added.append(row)
        }
        let newID = await firstValue(in: session, "SELECT MAX(id) FROM quarry_demo.customers WHERE name = 'Self-Test Row'")
        check("S-010 auto_increment fills in after save",
              newID != nil && added.first.map { content.grid.rows[$0][id] == .text(newID!) } == true
              && added.first.map { content.grid.rows[$0][created] != .text("current_timestamp()") } == true
              && content.draft == nil && content.editError == nil,
              content.editError?.message ?? "\(added.first.map { content.grid.rows[$0] } ?? [])")
        for _ in 1...2 {
            content.selection = [added.last ?? 0]
            session.duplicateRow()
            await session.currentLoad?.value
            guard let row = content.draft?.row else { break }
            session.endRowEdit(row: row, cancelled: false)
            await session.currentLoad?.value
            added.append(row)
        }
        check("S-010 Duplicate Row copies the row with a new id",
              await firstValue(in: session, "SELECT COUNT(DISTINCT id) FROM quarry_demo.customers WHERE name = 'Self-Test Row'") == "3",
              content.editError?.message ?? "")

        // The grid copies the selection as one INSERT.
        let coordinator = DataGrid.Coordinator()
        let scroll = DataGrid.makeScrollView(coordinator: coordinator, accessibilityLabel: "Self-test")
        coordinator.data = content.grid
        coordinator.insertTable = DataGrid.InsertTarget(table: "customers", engine: .mysql)
        coordinator.rebuildColumns()
        coordinator.table?.reloadData()
        scroll.layoutSubtreeIfNeeded()
        coordinator.table?.selectRowIndexes(IndexSet(added), byExtendingSelection: false)
        let insert = coordinator.copyText(.insert) ?? ""
        check("S-010 Copy as SQL INSERT holds the selected rows",
              insert.hasPrefix("INSERT INTO `customers` (`id`, `name`") && insert.components(separatedBy: "'Self-Test Row'").count == 4,
              insert)

        if let table = coordinator.table { pasteboardCopies(table: table, rows: added.count) }

        content.selection = IndexSet(added)
        session.deleteRows()
        check("S-010 deleting 3 rows asks once", content.pendingDelete?.count == 3, "\(content.pendingDelete.map(Array.init) ?? [])")
        session.confirmDeleteRows()
        await session.currentLoad?.value
        check("S-010 and removes 3",
              await firstValue(in: session, "SELECT COUNT(*) FROM quarry_demo.customers WHERE name = 'Self-Test Row'") == "0"
              && content.grid.rows.count == start && content.editError == nil,
              content.editError?.message ?? "")
    }

    // MARK: S-014

    static func filtering(session: Session) async {
        session.database = "quarry_demo"
        await session.currentLoad?.value
        session.view = .content
        session.selectedObjectID = "table:customers"
        await session.currentLoad?.value
        let content = session.content
        func count(_ condition: String) async -> Int {
            let sql = "SELECT COUNT(*) FROM quarry_demo.customers WHERE " + condition
            return await firstValue(in: session, sql).flatMap(Int.init) ?? -1
        }
        func filter(_ column: String, _ op: RowFilter.Operator, _ value: String = "", _ second: String = "") async {
            content.filter.draft = FilterTree(RowFilter(column: column, op: op, value: value, secondValue: second))
            session.applyFilter()
            await session.currentLoad?.value
        }
        func values(_ column: String) -> [CellValue] {
            guard let index = content.grid.columns.firstIndex(where: { $0.title == column }) else { return [] }
            return content.grid.rows.map { $0[index] }
        }
        let all = await count("1")

        check("S-014 the bar offers the table's columns", content.filter.columns.first == "id" && content.filter.columns.contains("country"),
              "\(content.filter.columns)")
        await filter("country", .equals, "US")
        let us = await count("country = 'US'")
        check("S-014 country = US leaves only US rows", !values("country").isEmpty && values("country").allSatisfy { $0 == .text("US") }
              && content.grid.rows.count == us, "\(values("country"))")
        check("S-014 the status says N of M rows", content.statusLabel == "\(us) of \(all) rows", content.statusLabel)

        await filter("notes", .contains, "\\")
        check("S-014 contains matches a backslash literally", values("name") == [.text("Margaret Hamilton")], "\(values("name"))")
        await filter("country", .isIn, "GB, NL")
        check("S-014 IN takes a comma-separated list", content.grid.rows.count == (await count("country IN ('GB','NL')")))
        await filter("email", .isNull)
        check("S-014 IS NULL finds NULLs", values("name") == [.text("Katherine Johnson")], "\(values("name"))")
        await filter("name", .equals, "x' OR '1'='1")
        check("S-014 a quote in the value can't widen the filter", content.grid.rows.isEmpty && content.load.error == nil
              && content.statusLabel == "0 of \(all) rows", content.load.error?.message ?? content.statusLabel)

        session.clearFilter()
        await session.currentLoad?.value
        check("S-014 Clear Filter shows every row", !content.isFiltered && content.grid.rows.count == all
              && content.statusLabel == "Rows 1–\(all) of \(all)", content.statusLabel)

        // S-015: rules in groups, built with the editor's own + and ⇥.
        func set(_ id: UUID, _ rule: RowFilter) { content.filter.draft.setRule(id, rule) }
        func run() async {
            session.applyFilter()
            await session.currentLoad?.value
        }
        content.filter.draft = FilterTree()
        content.filter.focusedRuleID = nil
        check("S-015 the All line is there with no rules", content.filter.draft.rows.count == 1
              && content.filter.draft.rows[0].kind == .header(.all, isRoot: true))
        session.addFilterRule()
        let first = content.filter.draft.rules.first
        check("S-015 a new rule starts on the auto-increment column, = and empty",
              first?.rule == RowFilter(column: "id") && content.filter.focus?.rule == first?.id, "\(String(describing: first?.rule))")

        // Typing filters after a pause, with no Filter button.
        let clock = ContinuousClock()
        let typed = clock.now
        if let first { set(first.id, RowFilter(column: "id", op: .lessOrEqual, value: "3")) }
        await content.filter.pending?.value
        await session.currentLoad?.value
        let waited = clock.now - typed
        check("S-015 typing filters after half a second on an indexed column",
              values("id") == [.text("1"), .text("2"), .text("3")] && waited >= .milliseconds(450) && waited < .milliseconds(900),
              "\(values("id")) after \(waited)")
        if let first { set(first.id, RowFilter(column: "country", value: "US")) }
        await run()
        content.filter.focusedRuleID = first?.id
        session.addFilterRule()
        let second = content.filter.draft.rules[1].id
        check("S-015 + adds the rule below, not set, so the rows stay",
              content.filter.draft.rules.map(\.id).first == first?.id && content.filter.draft.whereClause == "`country` = 'US'"
              && content.filter.pending == nil)
        set(second, RowFilter(column: "email", op: .isNull))
        content.filter.addGroup(below: second)
        let third = content.filter.draft.rules[2].id
        check("S-015 ⇥ adds an Any group below the rule",
              content.filter.draft.rows.map(\.depth) == [0, 1, 1, 1, 2]
              && content.filter.draft.rows[3].kind == .header(.any, isRoot: false))
        set(third, RowFilter(column: "name", op: .startsWith, value: "Mar"))
        content.filter.move(second, below: content.filter.draft.rows[3].id)
        await run()
        check("S-015 dragging a rule into the group: All of (US, Any of (no email, name starts with Mar))",
              Set(values("name")) == [.text("Katherine Johnson"), .text("Margaret Hamilton")], "\(values("name"))")
        content.filter.draft.setMatch(content.filter.draft.root.id, .none)
        await run()
        let expectedNone = await count("NOT (country = 'US' OR (email IS NULL OR name LIKE 'Mar%'))")
        check("S-015 None of the following", content.grid.rows.count == expectedNone && expectedNone > 0,
              "\(content.grid.rows.count) vs \(expectedNone)")
        content.filter.draft = FilterTree(RowFilter(column: "id", op: .between, value: "1", secondValue: "2"))
        content.filter.draft.setMatch(content.filter.draft.root.id, .any)
        let jp = content.filter.draft.add(RowFilter(column: "country", value: "JP"), below: content.filter.draft.rules[0].id)
        await run()
        check("S-015 BETWEEN inside Any keeps its own AND", values("id") == [.text("1"), .text("2"), .text("10")], "\(values("id"))")
        _ = jp
        await content.filter.remove(content.filter.draft.root.id)?.value
        check("S-015 − on the All line removes every rule and shows every row",
              content.filter.draft.isEmpty && content.filter.draft.root.match == .any && !content.isFiltered
              && content.grid.rows.count == all)

        session.selectedObjectID = "table:events"
        await session.currentLoad?.value
        check("S-014 another table starts unfiltered", !content.isFiltered && content.filter.draft.isEmpty)
        await filter("id", .between, "1", "2500")
        check("S-014 BETWEEN pages through its matches", content.statusLabel == "Rows 1–1,000 · 2,500 of 100,000 rows",
              content.statusLabel)
        session.clearFilter()
        await session.currentLoad?.value

        // S-061: a WHERE clause clause as SQL, beside the rules; an error keeps it.
        session.selectedObjectID = "table:customers"
        await session.currentLoad?.value
        content.filter.draft = FilterTree()
        session.addTypedClause()
        let clause = content.filter.draft.rules.first
        check("S-061 Add WHERE Clause adds a WHERE clause rule with the cursor in it",
              clause?.rule.op == .sql && content.filter.focus?.rule == clause?.id, "\(String(describing: clause?.rule))")
        if let clause {
            content.filter.draft.setRule(clause.id, RowFilter(column: "id", op: .sql, value: "id <= 3 OR country = 'JP'"))
            try? await Task.sleep(for: .milliseconds(1300))
            check("S-061 typing a clause waits for Return", !content.isFiltered && content.filter.pending == nil)
            session.applyFilter()
            await session.currentLoad?.value
            let expected = await count("id <= 3 OR country = 'JP'")
            check("S-061 a typed clause filters Content", content.load.error == nil && content.grid.rows.count == expected
                  && expected > 3, "\(content.grid.rows.count) of \(expected) \(content.load.error?.message ?? "")")
            content.filter.draft.add(RowFilter(column: "country", value: "JP"), below: clause.id)
            session.applyFilter()
            await session.currentLoad?.value
            let both = await count("(id <= 3 OR country = 'JP') AND country = 'JP'")
            check("S-061 a typed OR stays inside its parentheses", content.grid.rows.count == both, "\(content.grid.rows.count) of \(both)")
            let broken = "id <= 3 AND nope = 1 -- note"
            content.filter.draft.setRule(clause.id, RowFilter(column: "id", op: .sql, value: broken))
            session.applyFilter()
            await session.currentLoad?.value
            check("S-061 a server error shows, the old rows go, and the clause stays",
                  content.load.error != nil && content.grid.rows.isEmpty && content.statusLabel == "The filter failed"
                  && content.filter.draft.rule(clause.id)?.value == broken
                  && content.filter.draft.rules.count == 2, content.load.error?.message ?? "no error")
            content.filter.draft = FilterTree(RowFilter(column: "id", op: .sql, value: "id = 1 -- just one"))
            session.applyFilter()
            await session.currentLoad?.value
            check("S-061 a trailing -- comment ends at the line break", content.load.error == nil
                  && content.grid.rows.count == 1, content.load.error?.message ?? "\(content.grid.rows.count) rows")
        }
        session.clearFilter()
        await session.currentLoad?.value

        let items = menuItems { $0.keyEquivalent == "f" && $0.keyEquivalentModifierMask == [.command] }
        check("S-014 ⌘F is Table > Filter Content and nothing else", items.map(\.title) == ["Filter Content"], "\(items.map(\.title))")
        let shift = menuItems { $0.keyEquivalent.lowercased() == "f" && $0.keyEquivalentModifierMask.contains(.shift) }
        check("S-015 ⇧⌘F adds a rule, ⌥⇧⌘F adds a group",
              shift.map(\.title) == ["Add Filter Rule", "Add Filter Group"], "\(shift.map(\.title))")
        let control = menuItems { $0.keyEquivalent == "f" && $0.keyEquivalentModifierMask == [.command, .option, .control] }
        check("S-061 ⌃⌥⌘F adds a WHERE clause", control.map(\.title) == ["Add WHERE Clause"], "\(control.map(\.title))")
    }

    // MARK: S-017

    static func foreignKeyLinks(session: Session) async {
        session.database = "quarry_demo"
        await session.currentLoad?.value
        session.history.removeAll()
        session.view = .content
        session.selectedObjectID = "table:order_items"
        await session.currentLoad?.value
        let content = session.content
        guard let orderID = content.grid.columns.firstIndex(where: { $0.title == "order_id" }),
              let quantity = content.grid.columns.firstIndex(where: { $0.title == "quantity" }), !content.grid.rows.isEmpty else {
            check("S-017 order_items loads", false)
            return
        }
        check("S-017 order_id and product_id link, quantity doesn't",
              content.grid.columns[orderID].isLinked && content.grid.columns.filter(\.isLinked).count == 2
                && !content.grid.columns[quantity].isLinked)
        check("S-017 the arrow's help names the row", content.linkHelp(row: 0, column: orderID)?.hasPrefix("Open the orders row where id = ") ?? false,
              content.linkHelp(row: 0, column: orderID) ?? "none")

        // The grid draws the arrow in linked cells only, and a click on it follows.
        let coordinator = DataGrid.Coordinator()
        let scroll = DataGrid.makeScrollView(coordinator: coordinator, accessibilityLabel: "Self-test")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        var followed: [(Int, Int)] = []
        var inNewTab: [Bool] = []
        coordinator.links = DataGrid.LinkHook(help: content.linkHelp, follow: {
            followed.append(($0, $1))
            inNewTab.append($2)
        })
        coordinator.data = content.grid
        coordinator.rebuildColumns()
        coordinator.table?.reloadData()
        scroll.layoutSubtreeIfNeeded()
        func cell(_ column: Int) -> GridCellView? {
            guard let table = coordinator.table,
                  let at = table.tableColumns.firstIndex(where: { coordinator.dataColumn($0) == column }) else { return nil }
            return table.view(atColumn: at, row: 0, makeIfNecessary: true) as? GridCellView
        }
        check("S-017 linked cells show the arrow", cell(orderID)?.hasLink == true && cell(quantity)?.hasLink == false)
        if let action = cell(orderID)?.accessibilityCustomActions()?.first {
            _ = action.handler?()
        }
        check("S-017 the arrow follows its own cell", followed.first.map { $0 == (0, orderID) } ?? false, "\(followed)")
        // A click goes to the view hit testing picks, as the window sends it:
        // the table, not the cell (an offscreen window doesn't dispatch events).
        followed = []
        inNewTab = []
        if let linked = cell(orderID) {
            let arrow = linked.convert(NSPoint(x: linked.bounds.width - 9, y: linked.bounds.midY), to: nil)
            let click = { (type: NSEvent.EventType) in
                NSEvent.mouseEvent(with: type, location: arrow, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let down = click(.leftMouseDown), let up = click(.leftMouseUp), let root = window.contentView?.superview {
                window.postEvent(up, atStart: false)
                root.hitTest(root.convert(arrow, from: nil))?.mouseDown(with: down)
            }
        }
        check("S-017 clicking the arrow follows the link", followed.first.map { $0 == (0, orderID) } ?? false, "\(followed)")
        check("S-037 a plain click follows in place", inNewTab == [false], "\(inNewTab)")
        followed = []
        inNewTab = []
        if let linked = cell(orderID), let root = window.contentView?.superview {
            let arrow = linked.convert(NSPoint(x: linked.bounds.width - 9, y: linked.bounds.midY), to: nil)
            if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: arrow, modifierFlags: [.command], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                root.hitTest(root.convert(arrow, from: nil))?.mouseDown(with: down)
            }
        }
        check("S-037 ⌘-clicking the arrow asks for a new tab", followed.first.map { $0 == (0, orderID) } ?? false && inNewTab == [true],
              "\(followed) \(inNewTab)")
        window.close()

        content.sort(by: "quantity", ascending: false).map { session.currentLoad = $0 }
        await session.currentLoad?.value
        let itemsValue = content.grid.rows[0][orderID].plainText ?? ""
        await session.followLink(row: 0, column: orderID)?.value
        check("S-017 following order_id opens orders filtered to that id",
              session.selectedObjectID == "table:orders" && session.view == .content
                && content.filter.appliedClause == "`id` = '\(itemsValue)'" && content.grid.rows.count == 1
                && content.grid.rows.first?.first?.plainText == itemsValue,
              "\(session.selectedObjectID ?? "nil") \(content.filter.appliedClause ?? "no filter") \(content.grid.rows.count) rows")
        check("S-017 the filter shows the rule", content.filter.draft.rules.first?.rule == RowFilter(column: "id", value: itemsValue))
        check("S-017 Back is enabled", session.history.canGoBack && MenuState.shared.snapshot.phase == .connected)

        await session.goBack()?.value
        check("S-017 Back returns to order_items with its sort",
              session.selectedObjectID == "table:order_items" && content.sortColumn == "quantity" && !content.ascending
                && !content.isFiltered && content.grid.rows.first?[orderID].plainText == itemsValue,
              "\(session.selectedObjectID ?? "nil") sort \(content.sortColumn ?? "none")")
        await session.goForward()?.value
        check("S-017 Forward opens the order again", session.selectedObjectID == "table:orders" && content.grid.rows.count == 1)
        await session.goBack()?.value
        check("S-017 a field with no foreign key has nothing to follow", content.link(row: 0, column: quantity) == nil)
        // order_items has no `id`; its key starts with order_id.
        content.sort(by: "order_id", ascending: true).map { session.currentLoad = $0 }
        await session.currentLoad?.value
        session.history.removeAll()
    }

    // MARK: S-062

    static func savedFilters(model: AppModel, session: Session) async {
        session.database = "quarry_demo"
        await session.currentLoad?.value
        session.view = .content
        session.selectedObjectID = "table:customers"
        await session.currentLoad?.value
        let content = session.content
        for filter in session.savedFilters { model.deleteSavedFilter(filter.uid) }

        // US customers by an id still to be typed.
        var tree = FilterTree(RowFilter(column: "country", value: "US"))
        tree.add(RowFilter(column: "id", op: .lessOrEqual), below: tree.rules[0].id)
        content.filter.draft = tree
        session.requestSaveFilter()
        check("S-062 Save asks for a name", content.filter.isNaming && content.filter.name.isEmpty)
        session.saveFilter(named: "  US up to id ")
        content.filter.isNaming = false
        let saved = session.savedFilters
        check("S-062 the filter is saved on customers with its empty rule",
              saved.map(\.name) == ["US up to id"] && saved.first?.filter?.rules.map(\.rule) == tree.rules.map(\.rule)
              , "\(saved.map(\.name)) \(String(describing: saved.first?.filter?.rules.map(\.rule)))")
        try? await Task.sleep(for: .milliseconds(100))
        check("S-062 Table > Saved Filters lists it", MenuState.shared.snapshot.savedFilters.map(\.name) == ["US up to id"],
              "\(MenuState.shared.snapshot.savedFilters.map(\.name))")

        session.clearFilter()
        await session.currentLoad?.value
        session.openSavedFilter(saved[0].uid)
        await session.currentLoad?.value
        let unset = content.filter.draft.rules.last?.id
        check("S-062 opening it filters at once and puts the cursor on the empty rule",
              content.grid.rows.count == 4 && content.statusLabel.hasPrefix("4 of ")
              && content.filter.focus?.rule == unset && unset != nil, content.statusLabel)
        if let unset { content.filter.draft.setRule(unset, RowFilter(column: "id", op: .lessOrEqual, value: "4")) }
        session.applyFilter()
        await session.currentLoad?.value
        check("S-062 typing the one value finishes it", content.grid.rows.count == 2)

        session.requestSaveFilter()
        check("S-062 Save offers the opened filter's name", content.filter.name == "US up to id")
        session.saveFilter(named: content.filter.name)
        content.filter.isNaming = false
        check("S-062 saving under the same name replaces it", session.savedFilters.count == 1
              && session.savedFilters.first?.filter?.rules.last?.rule.value == "4")

        session.selectedObjectID = "table:orders"
        await session.currentLoad?.value
        check("S-062 another table has its own saved filters", session.savedFilters.isEmpty)
        session.selectedObjectID = "table:customers"
        await session.currentLoad?.value

        let save = menuItems { $0.title == "Save Filter…" }.first
        check("S-062 Table > Save Filter… is ⌥⌘S", save?.keyEquivalent == "s" && save?.keyEquivalentModifierMask == [.command, .option],
              "\(save?.keyEquivalent.unicodeScalars.map { $0.value } ?? []) \(save?.keyEquivalentModifierMask.rawValue ?? 0)")
        session.deleteSavedFilter(saved[0].uid)
        check("S-062 Delete removes it", session.savedFilters.isEmpty && model.savedFilters.isEmpty)
        session.clearFilter()
        await session.currentLoad?.value
    }

    // MARK: S-016

    /// ⌥⌘C and ⌃⌥⌘C are in the Edit menu, and the grid's actions put the
    /// expected text on the pasteboard. The user's clipboard comes back after.
    static func pasteboardCopies(table: NSTableView, rows: Int) {
        func item(_ title: String) -> NSMenuItem? { menuItems { $0.title == title }.first }
        let names = item("Copy with Column Names"), insert = item("Copy as SQL INSERT")
        check("S-016 Edit menu has ⌥⌘C and ⌃⌥⌘C",
              names?.keyEquivalent == "c" && names?.keyEquivalentModifierMask == [.command, .option]
              && insert?.keyEquivalent == "c" && insert?.keyEquivalentModifierMask == [.command, .option, .control],
              "\(names?.keyEquivalentModifierMask.rawValue ?? 0) \(insert?.keyEquivalentModifierMask.rawValue ?? 0)")

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
        } ?? []
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            })
        }
        _ = table.tryToPerform(#selector(GridCopying.copyWithColumnNames(_:)), with: nil)
        let withNames = pasteboard.string(forType: .string) ?? ""
        let lines = withNames.components(separatedBy: "\n")
        check("S-016 ⌥⌘C copies a header line and one tab-separated line per row",
              lines.count == rows + 1 && lines[0].hasPrefix("id\tname") && lines.dropFirst().allSatisfy { $0.contains("\tSelf-Test Row\t") },
              withNames)
        _ = table.tryToPerform(#selector(GridCopying.copyAsSQLInsert(_:)), with: nil)
        let sql = pasteboard.string(forType: .string) ?? ""
        check("S-016 ⌃⌥⌘C copies one INSERT for the rows",
              sql.hasPrefix("INSERT INTO `customers` (`id`, `name`") && sql.hasSuffix(");")
              && sql.components(separatedBy: "'Self-Test Row'").count == rows + 1,
              sql)
    }
}
