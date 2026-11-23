import AppKit
import QuarryKit
import SwiftData

/// Self-test: Query: running, cancelling, editable results, saved queries, history, editor helpers and the Console (S-007, S-031 to S-036, S-039).
extension SelfTest {
    // MARK: S-007

    static func querying(session: Session) async {
        session.view = .query
        // Typing and caret moves leave the window and the menus alone (review 2026-11-19).
        session.query.text = "SELECT"
        nonisolated(unsafe) var menusChanged = false
        withObservationTracking { _ = session.menuSnapshot } onChange: { menusChanged = true }
        for offset in 0..<20 {
            session.query.text += " 1"
            session.query.cursor = offset
            session.query.selection = NSRange(location: offset, length: 0)
        }
        check("Typing and moving the caret in the query editor leave the menus alone", !menusChanged)
        withObservationTracking { _ = session.menuSnapshot } onChange: { menusChanged = true }
        session.query.text = " "
        check("Emptying the query editor updates the menus (Save Query… turns off)",
              menusChanged && !session.menuSnapshot.hasQueryText)

        session.query.text = "SELECT 1 AS a;\nSELECT 2 AS b;\n"
        session.query.cursor = 20
        session.runCurrentStatement()
        await session.currentLoad?.value
        check("S-007 ⌘R runs only the statement at the cursor", session.query.results.columns.map(\.title) == ["b"])
        session.runAll()
        await session.currentLoad?.value
        check("S-007 ⌥⌘R runs every statement", session.query.status.hasPrefix("2 statements"), session.query.status)

        session.query.text = "SELECT 1;\nSELEC oops;\nSELECT 3;"
        session.runAll()
        await session.currentLoad?.value
        check("S-007 an error names its line", session.query.error != nil && session.query.errorLine == 2,
              "line \(session.query.errorLine ?? -1)")
        check("S-007 earlier results stay visible", session.query.results.columns.first?.title == "1")
        check("S-007 Run All stops at the error", session.query.status.hasPrefix("1 statement"), session.query.status)

        // S-036: Cancel stops SLEEP(30) on the server within 1 s, and Run All runs nothing after it.
        session.query.text = "SELECT SLEEP(30);\nSELECT 'after' AS later;"
        session.runAll()
        try? await Task.sleep(for: .milliseconds(300))
        check("S-036 Cancel Query is enabled while a query runs", session.menuSnapshot.canCancelQuery)
        let clock = ContinuousClock()
        let start = clock.now
        session.cancelQuery()
        check("S-036 the main thread stays free (cancel returns at once)", clock.now - start < .milliseconds(50))
        await session.currentLoad?.value
        let took = clock.now - start
        check("S-036 SLEEP(30) stops within 1 s", took < .seconds(1), "\(took)")
        check("S-036 status says it was cancelled", session.query.status.hasPrefix("Cancelled in statement 1 of 2"),
              session.query.status)
        check("S-036 no error and the next statement did not run",
              session.query.error == nil && session.query.results.columns.first?.title != "later")
        check("S-036 Cancel Query is disabled again", !session.query.isRunning && !session.menuSnapshot.canCancelQuery)
        session.query.text = "SELECT 'still' AS works;"
        session.runAll()
        await session.currentLoad?.value
        check("S-036 the connection still works after a cancel", session.query.results.columns.first?.title == "works")

        // S-031: completions from the fixture's catalog, within 150 ms once it is loaded.
        session.refreshCompletionCatalog()
        await session.loadCompletionTables("quarry_demo")?.value
        await until { session.completionTables["quarry_demo"] != nil }
        let typed = "SELECT * FROM ord"
        let completionStart = clock.now
        let tables = session.completions(typed, cursor: (typed as NSString).length, explicit: false)
        let completionTime = clock.now - completionStart
        check("S-031 after FROM, \"ord\" lists the tables and view that start with it",
              tables?.items.map(\.name) == ["order_items", "orders", "order_totals"], "\(tables?.items.map(\.name) ?? [])")
        check("S-031 the list is ready within 150 ms", completionTime < .milliseconds(150), "\(completionTime)")
        let aliased = "SELECT o. FROM orders o"
        let columns = session.completions(aliased, cursor: 9, explicit: false)?.items.map(\.name) ?? []
        check("S-031 after \"o.\" come the columns of orders", columns.first == "id" && columns.contains("customer_id"), "\(columns)")
        let other = "SELECT * FROM quarry_legacy."
        _ = session.completions(other, cursor: (other as NSString).length, explicit: false)
        await until { session.completionTables["quarry_legacy"] != nil }
        let legacy = session.completions(other, cursor: (other as NSString).length, explicit: false)?.items.map(\.name) ?? []
        check("S-031 another database's tables load when asked for", !legacy.isEmpty, "\(legacy)")
        session.query.text = "CREATE TABLE quarry_demo.completion_probe (id INT); DROP TABLE quarry_demo.completion_probe;"
        session.runAll()
        await session.currentLoad?.value
        check("S-031 a schema change empties the cached catalog", session.completionTables["quarry_legacy"] == nil)
        await queryHistory(session)
        savedQueries(session)
        editorHelpers()
        await editableResults(session)
    }

    // MARK: S-035

    static func editableResults(_ session: Session) async {
        session.query.text = "SELECT id, name AS who, UPPER(country) AS cc FROM quarry_demo.customers WHERE id = 1"
        session.runAll()
        await session.currentLoad?.value
        check("S-035 a one-table result with its key is editable", session.canEditQueryCell(row: 0, column: 1))
        check("S-035 a computed column is read-only and says why on hover",
              !session.canEditQueryCell(row: 0, column: 2)
                && session.query.results.columns[2].help == "Read-only: computed by the query, not stored in a table.")
        let old = session.query.results.rows.first?[1] ?? .null
        session.editQueryCell(row: 0, column: 1, to: .text("Ada King"))
        await session.currentLoad?.value
        let stored = try? await session.client?.run("SELECT name FROM quarry_demo.customers WHERE id = 1").rows.first?.first
        check("S-035 editing a result cell saves it with an UPDATE",
              stored == .text("Ada King") && session.query.results.rows[0][1] == .text("Ada King") && session.query.editError == nil,
              "\(String(describing: stored))")
        session.editQueryCell(row: 0, column: 1, to: old)
        await session.currentLoad?.value

        session.query.text = "SELECT o.id, o.status, c.name FROM quarry_demo.orders o JOIN quarry_demo.customers c ON c.id = o.customer_id"
        session.runAll()
        await session.currentLoad?.value
        check("S-035 a JOIN column is read-only without its table's key, and says why",
              !session.canEditQueryCell(row: 0, column: 2)
                && session.query.results.columns[2].help == "Read-only: add id (the primary key of customers) to the SELECT to edit this column.",
              session.query.results.columns.last?.help ?? "no help")
        check("S-035 the JOIN's own keyed table stays editable", session.canEditQueryCell(row: 0, column: 1))
        session.query.text = "SELECT 1 AS one"
        session.runAll()
        await session.currentLoad?.value
        check("S-035 a SELECT with no table is read-only", !session.query.editing.hasEditableColumns)
    }

    // MARK: S-034

    static func savedQueries(_ session: Session) {
        guard let model = session.model else { return check("S-034 the session has a store", false) }
        model.importSavedQueries([], replacing: true)
        session.view = .query
        session.query.text = "SELECT 'a' AS a;\nSELECT 'b' AS b;"
        session.query.cursor = 20
        session.query.selection = NSRange(location: 20, length: 0)
        check("S-034 Save Query… is enabled with SQL in the editor", session.menuSnapshot.hasQueryText)
        session.beginSaveQuery()
        let draft = session.saveQueryDraft
        check("S-034 the sheet offers the statement at the cursor or the whole editor",
              draft?.statement == "SELECT 'b' AS b;" && draft?.offersChoice == true && draft?.name == "SELECT 'b' AS b;",
              "\(String(describing: draft?.statement)) \(String(describing: draft?.name))")
        draft?.name = "  Letter B "
        session.saveQuery()
        check("S-034 Save stores the query under its trimmed name and closes the sheet",
              session.saveQueryDraft == nil && model.savedQuery(named: "letter b")?.text == "SELECT 'b' AS b;")
        session.query.selection = NSRange(location: 0, length: 15)
        session.beginSaveQuery()
        check("S-034 a selection is what Current Statement saves", session.saveQueryDraft?.statement == "SELECT 'a' AS a")
        session.saveQueryDraft?.part = .editor
        session.saveQueryDraft?.name = "Letter B"
        check("S-034 a name in use reads Replace", session.saveQueryDraft?.replaces == true)
        session.saveQuery()
        check("S-034 Replace keeps one query with the new text",
              model.savedQueries.count == 1 && model.savedQueries.first?.text == session.query.text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let container = session.model?.container {
            let stored = (try? ModelContext(container).fetch(FetchDescriptor<SavedQuery>())) ?? []
            check("S-034 saved queries are kept in the store", stored.count == 1, "\(stored.count)")
        }
        session.query.insertRequest = nil
        session.insertSavedQuery("SHOW TABLES")
        check("S-034 choosing a saved query inserts it as its own Undo step",
              session.query.insertRequest == "SHOW TABLES" && session.query.insertActionName == "Insert Saved Query")
        session.query.insertRequest = nil

        // Export Selected… then Import…: a clash gets " 2", an exact copy is skipped.
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "quarry-selftest-\(UUID().uuidString).spf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try SavedQueryFile.encode([.init(name: "Letter B", query: "SELECT 2"), model.savedQueries[0].item]).write(to: url)
            let added = model.importSavedQueries(try SavedQueriesWindow.items(in: url), replacing: false)
            check("S-034 import adds a clashing name as \"Letter B 2\" and skips the exact copy",
                  added.map(\.name) == ["Letter B 2"] && model.savedQueries.map(\.name) == ["Letter B", "Letter B 2"],
                  "\(model.savedQueries.map(\.name))")
            let copy = model.duplicateSavedQuery(model.savedQueries[0].uid)
            check("S-034 Duplicate names the copy", copy?.name == "Letter B copy", "\(String(describing: copy?.name))")
            model.importSavedQueries(try SavedQueriesWindow.items(in: url), replacing: true)
            check("S-034 Import by Replacing leaves only the file's queries", model.savedQueries.count == 2, "\(model.savedQueries.count)")
        } catch {
            check("S-034 export and import", false, "\(error)")
        }
        model.deleteSavedQueries(Set(model.savedQueries.map(\.uid)))
        check("S-034 Delete All empties the list", model.savedQueries.isEmpty)
    }

    // MARK: S-033

    static func queryHistory(_ session: Session) async {
        session.clearHistory()
        for text in ["SELECT 'h1' AS h;", "SELECT 'h2' AS h;", "  SELECT 'h1' AS h ;\n"] {
            session.query.text = text
            session.runAll()
            await session.currentLoad?.value
        }
        check("S-033 each run is recorded once, newest first",
              session.queryHistory.map(\.text) == ["SELECT 'h1' AS h", "SELECT 'h2' AS h"], "\(session.queryHistory.map(\.text))")
        if let key = session.historyKey, let container = session.model?.container {
            let fresh = ModelContext(container)
            let stored = (try? fresh.fetch(FetchDescriptor<QueryHistoryEntry>()))?.filter { $0.serverKey == key } ?? []
            check("S-033 history is saved in the store, so it survives a relaunch", stored.count == 2, "\(stored.count)")
        } else {
            check("S-033 the session has a history key and a store", false)
        }
        check("S-033 Previous and Next Query from History are enabled", session.menuSnapshot.hasQueryHistory)
        var steps: [String?] = []
        for older in [true, true, true, false] {
            session.query.insertRequest = nil
            session.stepHistory(older: older)
            steps.append(session.query.insertRequest)
        }
        check("S-033 Previous goes older, stops at the oldest, Next comes back",
              steps == ["SELECT 'h1' AS h", "SELECT 'h2' AS h", nil, "SELECT 'h1' AS h"], "\(steps)")
        session.query.isInsertingHistory = false
        session.queryTextChanged()
        check("S-033 typing starts again from the newest entry", session.query.historyStepper.offset == -1)
        session.query.insertRequest = nil
    }

    // MARK: S-032

    /// The editor's helpers in a real `SQLTextView`, with Undo, in an offscreen window.
    static func editorHelpers() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SQLTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        view.isRichText = false
        view.allowsUndo = true
        window.contentView = view
        window.makeFirstResponder(view)
        guard let undo = view.undoManager else { return check("S-032 the editor has an undo manager", false) }
        undo.groupsByEvent = false
        func type(_ text: String) {
            for character in text {
                grouped { view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            }
        }
        func reset(_ text: String, caret: Int) {
            view.string = text
            view.setSelectedRange(NSRange(location: caret, length: 0))
            undo.removeAllActions()
        }
        func grouped(_ edit: () -> Void) {
            undo.beginUndoGrouping()
            edit()
            undo.endUndoGrouping()
        }
        func perform(_ command: EditorCommand) { grouped { view.perform(command) } }

        reset("select", caret: 6)
        type(" * from t where id in (1)")
        check("S-032 keywords uppercase as they are typed, names do not",
              view.string == "SELECT * FROM t WHERE id IN (1)", view.string)
        check("S-032 typing ) over the inserted one steps over it", view.selectedRange().location == (view.string as NSString).length)

        reset("SELECT COUNT", caret: 12)
        type("(")
        let paired = view.string
        grouped { view.deleteBackward(nil) }
        check("S-032 ( adds ) and Delete removes both", paired == "SELECT COUNT()" && view.string == "SELECT COUNT", "\(paired) → \(view.string)")

        reset("SELECT 1;\nSELECT 2;", caret: 12)
        perform(.commentLine)
        let commented = view.string
        undo.undo()
        check("S-032 Comment Line comments the line and Undo restores it",
              commented == "SELECT 1;\n-- SELECT 2;" && view.string == "SELECT 1;\nSELECT 2;", commented)

        reset("SELECT *\nFROM t;\nSELECT 2;", caret: 10)
        perform(.commentStatement)
        let statement = view.string
        perform(.commentStatement)
        check("S-032 Comment Current Statement comments its lines and toggles back",
              statement == "-- SELECT *\n-- FROM t;\nSELECT 2;" && view.string == "SELECT *\nFROM t;\nSELECT 2;", statement)

        reset("SELECT 1;\nSELECT 2;", caret: 0)
        view.setSelectedRange(NSRange(location: 0, length: 19))
        perform(.shiftRight)
        let shifted = view.string
        perform(.shiftLeft)
        let unshifted = view.string
        undo.undo()
        check("S-032 Shift Right and Shift Left indent every selected line, Undo steps back",
              shifted == "\tSELECT 1;\n\tSELECT 2;" && unshifted == "SELECT 1;\nSELECT 2;" && view.string == shifted, shifted)

        reset("SELECT 1;\n\nSELECT *\nFROM t;", caret: 20)
        perform(.selectStatement)
        check("S-032 Select Current Statement selects what ⌘R would run",
              view.selectedRange() == NSRange(location: 11, length: 15), "\(view.selectedRange())")

        reset("SELECT 1;", caret: 3)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, characters: "/",
                                   charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44)
        var handled = false
        if let key { grouped { handled = window.performKeyEquivalent(with: key) } }
        check("S-032 the editor answers ⌘/ itself, also in sheets", handled && view.string == "-- SELECT 1;", view.string)

        reset("\tSELECT *", caret: 9)
        grouped { view.insertNewline(nil) }
        check("S-032 Return keeps the line's indent", view.string == "\tSELECT *\n\t", view.string.debugDescription)

        reset("SELECT 1;", caret: 0)
        view.setSelectedRange(NSRange(location: 0, length: 9))
        grouped { view.replaceSelection(with: "SHOW TABLES;", actionName: "Insert Query from History") }
        let replaced = view.string == "SHOW TABLES;" && view.selectedRange() == NSRange(location: 0, length: 12)
        undo.undo()
        check("S-033 a history step replaces the selection, selects it, and undoes in one step",
              replaced && view.string == "SELECT 1;", view.string)
        window.close()
    }

    // MARK: S-039

    static func console(session: Session) async {
        let item = menuItem("Show Console")
        check("S-039 View > Show Console is ⇧⌘K",
              item?.keyEquivalent.lowercased() == "k" && item?.keyEquivalentModifierMask == [.command, .shift])
        Console.shared.clear()
        session.view = .query
        session.query.text = "SELECT 39 AS console;\nSHOW TABLES;\nDO 39;\nSELEC broken;"
        session.runAll()
        await session.currentLoad?.value
        await until { Console.shared.messages.contains { $0.isError } }
        let messages = Console.shared.messages
        let texts = messages.map(\.text)
        check("S-039 the console lists each statement run, on its connection and database",
              ["SELECT 39 AS console;", "SHOW TABLES;", "DO 39;", "SELEC broken;"].allSatisfy(texts.contains)
                  && messages.first { $0.text == "DO 39;" }.map { $0.database == session.database && !$0.connection.isEmpty } == true,
              texts.joined(separator: " | "))
        // Other statements (the completion list's) may run in between, so look for the next error.
        let broken = messages.firstIndex { $0.text == "SELEC broken;" } ?? messages.endIndex
        let error = messages[broken...].first { $0.isError }
        check("S-039 an error follows its statement, marked as an error",
              error?.text.contains("1064") == true, error?.text ?? "none")
        let hidden = ConsoleFilter(showsSelectAndShow: false).apply(messages).map(\.text)
        check("S-039 hiding SELECT/SHOW statements filters them out",
              !hidden.contains("SELECT 39 AS console;") && !hidden.contains("SHOW TABLES;") && hidden.contains("DO 39;")
                  && hidden.contains("SELEC broken;"), hidden.joined(separator: " | "))
        Console.shared.clear()
        await until { !Console.shared.messages.contains { $0.text == "SELEC broken;" } }
        check("S-039 Clear empties the console", !Console.shared.messages.contains { $0.text == "SELEC broken;" })
    }
}
