import AppKit
import QuarryKit

/// S-068: SQLite files: open, browse, query, menus, and the file's states.
/// Every file lives in a fresh /tmp folder; the fixture is tools/fixture-sqlite.sql.
extension SelfTest {
    /// tools/fixture-sqlite.sql, passed in by tools/selftest.sh and tools/snap.sh.
    static var sqliteFixtureScript: String? { ProcessInfo.processInfo.environment["APP_SQLITE_FIXTURE"] }

    /// A new copy of the fixture as `name` in a fresh /tmp folder, made with the system's sqlite3.
    static func makeSQLiteFixture(named name: String = "quarry_demo.sqlite") -> URL? {
        guard let script = sqliteFixtureScript, let input = FileHandle(forReadingAtPath: script) else { return nil }
        let folder = URL(fileURLWithPath: "/tmp/Quarry-sqlite-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path]
        process.standardInput = input
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? url : nil
    }

    static func sqliteFiles(model: AppModel, session: Session) async {
        guard let url = makeSQLiteFixture() else {
            check("S-068 the SQLite fixture is made from tools/fixture-sqlite.sql", false, "APP_SQLITE_FIXTURE: \(sqliteFixtureScript ?? "unset")")
            return
        }
        // A tab on the Connect page, so the main window keeps its MySQL connection.
        let before = Tabs.lastOpened
        Tabs.open(beside: session.window, using: session.openWindowAction)
        guard let tab = await openedTab(after: before) else {
            check("S-068 a tab opens for the SQLite checks", false)
            return
        }
        await until { tab.window != nil }

        // The Connect form's fourth choice.
        check("S-068 Connect With offers SQLite File", ConnectionDetails.Transport.allCases.map(\.title).last == "SQLite File")
        tab.show(saved: nil)
        tab.form = ConnectionDetails(transport: .sqlite)
        tab.connect(model: model)
        check("S-068 Connect without a file asks for one", tab.connectProblem?.message == "Choose a SQLite file." && tab.phase == .disconnected)
        tab.form.file = (url.path as NSString).abbreviatingWithTildeInPath
        tab.connect(model: model)
        await tab.waitForConnect()
        await tab.currentLoad?.value
        await until { tab.selectedObjectID != nil }
        check("S-068 Connect opens the file on main, its first table, on Content",
              tab.phase == .connected && tab.databases == ["main"] && tab.database == "main"
                  && tab.selectedObjectID == "table:customers" && tab.view == .content,
              "\(tab.phase) \(tab.databases) \(tab.selectedObjectID ?? "nil") \(tab.view)")
        let version = SQLiteFile.version.split(separator: ".").prefix(2).joined(separator: ".")
        check("S-068 the subtitle names the file and SQLite", tab.subtitle == "quarry_demo.sqlite · SQLite \(version)", tab.subtitle)
        check("S-068 the sidebar shows tables and views of main",
              tab.objects.map(\.name) == ["customers", "events", "notes", "order_items", "orders", "products", "settings", "order_totals"],
              tab.objects.map(\.name).joined(separator: ", "))
        await sqliteBrowsing(tab)
        await sqliteEditing(tab)
        await sqliteQuerying(tab, model: model)
        await sqliteMenus(tab)
        await sqliteSaved(tab, model: model, url: url)
        await sqliteStates(tab, model: model)
        await sqliteTransfer(tab, model: model)
        await sqliteInfo(tab, model: model)
        await sqliteStructure(tab, model: model)
        closeTab(tab)
        session.window?.makeKeyAndOrderFront(nil)
    }

    static func sqliteBrowsing(_ tab: Session) async {
        let content = tab.content
        await until { content.grid.rows.count == 6 }
        check("S-068 Content shows the table's rows", content.grid.rows.count == 6 && content.paging.total == 6,
              "\(content.grid.rows.count) of \(content.paging.total)")
        content.sort(by: "name", ascending: false).map { tab.currentLoad = $0 }
        await tab.currentLoad?.value
        let names = content.grid.rows.compactMap { $0[1].plainText }
        check("S-068 Content sorts", names.first == "Margaret Hamilton" && names.last == "Ada Lovelace", names.joined(separator: ", "))
        content.filter.draft = FilterTree(RowFilter(column: "country", op: .equals, value: "UK"))
        tab.applyFilter()
        await tab.currentLoad?.value
        check("S-068 Content filters", content.grid.rows.count == 2 && content.paging.total == 2,
              "\(content.grid.rows.count) of \(content.paging.total) \(content.load.error?.message ?? "")")
        content.filter.draft = FilterTree(RowFilter(column: "name", op: .contains, value: "ing"))
        tab.applyFilter()
        await tab.currentLoad?.value
        check("S-068 a contains filter works", content.grid.rows.count == 1, content.load.error?.message ?? "\(content.grid.rows.count)")

        tab.selectedObjectID = "table:events"
        await tab.currentLoad?.value
        await until { content.paging.total == 2500 }
        check("S-068 Content pages a big table", content.paging.total == 2500 && content.grid.rows.count == content.paging.pageSize
                  && content.paging.hasNext, "\(content.grid.rows.count) of \(content.paging.total)")
        tab.movePage(by: 1)
        await tab.currentLoad?.value
        await until { content.grid.rows.first?.first == .text(String(content.paging.pageSize + 1)) }
        check("S-068 Next Page shows the next rows", content.grid.rows.first?.first == .text(String(content.paging.pageSize + 1)),
              content.grid.rows.first?.first?.plainText ?? "none")
        let amount = column(in: content.grid, "amount")
        check("S-068 REAL and NULL values show as stored",
              content.grid.rows.contains { $0[amount] == .null } && content.grid.rows.contains { $0[amount].plainText?.contains(".") == true })

        tab.selectedObjectID = "table:products"
        await tab.currentLoad?.value
        await until { content.grid.rows.count == 4 }
        check("S-068 a BLOB shows as bytes", content.grid.rows.first?[column(in: content.grid, "photo")] == .binary(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])))

        tab.view = .structure
        await tab.currentLoad?.value
        check("S-068 Structure lists the fields and indexes", tab.structure.names == ["id", "sku", "title", "price", "stock", "photo"]
                  && tab.structure.indexRowNames.contains("PRIMARY"), tab.structure.names.joined(separator: ", "))
        tab.view = .triggers
        await tab.currentLoad?.value
        check("S-068 Triggers lists the table's trigger", tab.triggers.triggers.map(\.name) == ["products_stock_check"])
        tab.selectedObjectID = "table:order_items"
        tab.view = .foreignKeys
        await tab.currentLoad?.value
        check("S-068 Foreign Keys lists the table's keys", tab.foreignKeys.keys.count == 2, "\(tab.foreignKeys.keys.count)")
        tab.view = .info
        await tab.currentLoad?.value
        check("S-068 Info shows the CREATE statement", tab.info.createStatement.hasPrefix("CREATE TABLE order_items"),
              tab.info.load.error?.message ?? tab.info.createStatement)
        tab.view = .content
        await tab.currentLoad?.value
    }

    static func sqliteQuerying(_ tab: Session, model: AppModel) async {
        tab.view = .query
        Console.shared.clear()
        tab.query.text = "SELECT kind, COUNT(*) AS n FROM events GROUP BY kind ORDER BY kind;"
        tab.runAll()
        await tab.currentLoad?.value
        check("S-068 Query runs a statement on the file",
              tab.query.results.columns.map(\.title) == ["kind", "n"] && tab.query.results.rows.count == 3,
              tab.query.error?.message ?? tab.query.status)
        await until { tab.queryHistory.first?.text.contains("GROUP BY kind") == true }
        check("S-068 the statement is in the file's query history", tab.queryHistory.first?.text.contains("GROUP BY kind") == true)
        await until { Console.shared.messages.contains { $0.text.contains("GROUP BY kind") } }
        check("S-068 the Console logs it under the file's name",
              Console.shared.messages.contains { $0.text.contains("GROUP BY kind") && $0.connection == "quarry_demo.sqlite" })
        tab.query.text = "UPDATE notes SET body = body WHERE rowid = 1;"
        tab.runAll()
        await tab.currentLoad?.value
        check("S-068 a change reports the rows it touched", tab.query.status.hasPrefix("1 row affected"), tab.query.status)

        tab.refreshCompletionCatalog()
        await tab.loadCompletionTables("main")?.value
        await until { tab.completionTables["main"] != nil }
        check("S-068 completions know the file's tables and columns",
              tab.completionTables["main"]?.first { $0.name == "orders" }?.columns.map(\.name).contains("customer_id") == true)

        // Cancel Query interrupts the statement (sqlite3_interrupt).
        tab.query.text = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) SELECT COUNT(*) FROM n;\nSELECT 'after' AS later;"
        tab.runAll()
        try? await Task.sleep(for: .milliseconds(300))
        let clock = ContinuousClock()
        let start = clock.now
        tab.cancelQuery()
        await tab.currentLoad?.value
        check("S-068 Cancel Query stops a SQLite statement within 1 s", clock.now - start < .seconds(1)
                  && tab.query.status.hasPrefix("Cancelled in statement 1 of 2") && tab.query.error == nil,
              "\(clock.now - start) \(tab.query.status) \(tab.query.error?.message ?? "")")
        tab.query.text = "SELECT 'still' AS works;"
        tab.runAll()
        await tab.currentLoad?.value
        check("S-068 the file still answers after a cancel", tab.query.results.columns.first?.title == "works")
        tab.view = .content
        await tab.currentLoad?.value
    }

    static func sqliteMenus(_ tab: Session) async {
        tab.window?.makeKeyAndOrderFront(nil)
        await until { MenuState.shared.active === tab }
        MenuState.shared.activate(tab)
        try? await Task.sleep(for: .milliseconds(300))
        let walked = walkMenuBar()
        var wrong: [String] = []
        for command in CommandMap.all where command.sqliteLacks != nil {
            let items = walked.filter { $0.menu == command.menu && command.titles.contains($0.title) }
            if items.isEmpty { wrong.append("\(command.title) is missing") }
            // A submenu's own item stays on; its choices are what gray out.
            if command.title == "View Using Encoding" {
                let choices = walked.filter { item in ViewEncoding.allCases.contains { $0.title == item.title } }
                if choices.isEmpty || choices.contains(where: \.isEnabled) { wrong.append("View Using Encoding's choices are on") }
            } else if items.contains(where: \.isEnabled) {
                wrong.append("\(command.title) is on")
            }
        }
        check("S-068 server-only commands gray out on a SQLite window", wrong.isEmpty, wrong.joined(separator: "; "))
        // S-072: the Database menu lists the file's own tools, and no server tools.
        let serverTools = CommandMap.all.filter { $0.only == .mysql }.filter { command in
            walked.contains { $0.menu == command.menu && $0.title == command.title }
        }
        let fileTools = CommandMap.all.filter { $0.only == .sqlite }.filter { command in
            !walked.contains { $0.menu == command.menu && $0.title == command.title }
        }
        check("S-072 a SQLite window's Database menu has the file's tools and no server tools",
              serverTools.isEmpty && fileTools.isEmpty,
              "shown: \(serverTools.map(\.title)) missing: \(fileTools.map(\.title))")
        let tips = ["User Accounts…", "Show Server Processes…", "New Database…"].map { title in
            menuItems { $0.title == title }.first?.toolTip ?? ""
        }
        check("S-068 a grayed server command says why",
              tips == ["SQLite files have no server, so there are no user accounts.",
                       "SQLite files have no server, so there are no server processes.",
                       "SQLite files have no server, so there are no other databases."], tips.joined(separator: " | "))
        let on = ["New Table…", "New View…", "Run All", "Show Create Statement…", "Refresh"].filter { title in
            !(walked.first { $0.title == title }?.isEnabled ?? false)
        }
        check("S-068 commands that work on a file stay on", on.isEmpty, on.joined(separator: ", "))
        check("S-068 the database menu has no New Database… and the star is gone",
              !tab.menuSnapshot.canEditDatabase && !tab.menuSnapshot.canDuplicateDatabase)
    }

    static func sqliteSaved(_ tab: Session, model: AppModel, url: URL) async {
        // Save Connection keeps the file with a bookmark, so a moved file is still found.
        let uid = model.save(tab.form, over: nil)
        let saved = model.savedConnection(uid)
        check("S-068 Save Connection keeps the file, its name and a bookmark",
              saved?.kind == .sqlite && saved?.displayName == "quarry_demo.sqlite" && saved?.fileBookmark != nil
                  && saved?.summary == (url.path as NSString).abbreviatingWithTildeInPath)
        tab.disconnect()
        let moved = url.deletingLastPathComponent().appending(path: "renamed.sqlite")
        try? FileManager.default.moveItem(at: url, to: moved)
        check("S-068 a moved file is found through its bookmark",
              saved?.details.fileURL?.resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path,
              saved?.details.file ?? "nil")
        tab.show(saved: saved)
        tab.connect(model: model)
        await tab.waitForConnect()
        check("S-068 the saved connection opens the moved file", tab.phase == .connected && tab.database == "main",
              tab.connectProblem?.message ?? "\(tab.phase)")

        // A file deleted while open shows Connection Lost.
        try? FileManager.default.removeItem(at: moved)
        tab.refresh()
        await tab.currentLoad?.value
        await until { tab.connectionLost }
        check("S-068 a file deleted while open shows Connection Lost", tab.connectionLost)
        tab.disconnect()

        // The saved connection now can't find it: Locate… and Remove Connection.
        tab.show(saved: model.savedConnection(uid))
        tab.connect(model: model)
        await tab.waitForConnect()
        check("S-068 a missing file says so", tab.connectProblem?.message == "Can’t find “renamed.sqlite”. It was moved or deleted."
                  && tab.connectProblem?.code == SQLiteFile.missingCode, tab.connectProblem?.message ?? "connected")
        model.delete(uid)
        tab.show(saved: nil)
    }

    static func sqliteStates(_ tab: Session, model: AppModel) async {
        // Not a SQLite file.
        let folder = URL(fileURLWithPath: "/tmp/Quarry-sqlite-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let notes = folder.appending(path: "notes.db")
        try? Data("plain text".utf8).write(to: notes)
        tab.form = ConnectionDetails(transport: .sqlite, file: notes.path)
        tab.connect(model: model)
        await tab.waitForConnect()
        check("S-068 a file that isn't SQLite says so", tab.connectProblem?.message == "“notes.db” isn’t a SQLite database.",
              tab.connectProblem?.message ?? "connected")
        check("S-068 File > Open… tells SQLite files from connection files",
              SQLiteFile.opens(makeSQLiteFixture() ?? notes) && !SQLiteFile.opens(notes))

        // Read only: the subtitle says so and edits gray out.
        guard let url = makeSQLiteFixture() else { return }
        tab.form = ConnectionDetails(transport: .sqlite, file: url.path, readOnly: true)
        tab.connect(model: model)
        await tab.waitForConnect()
        await tab.currentLoad?.value
        await until { !tab.content.grid.rows.isEmpty }
        check("S-068 a read-only file says so in the subtitle", tab.subtitle.hasSuffix("· Read Only"), tab.subtitle)
        check("S-068 edits gray out on a read-only file",
              !tab.content.canAddRow && !tab.content.canEdit(row: 0, column: 1) && !tab.menuSnapshot.canDeleteTables
                  && tab.menuSnapshot.isSQLite && !tab.menuSnapshot.canImport)
        // The sidebar's row menu reads the same rules as the Table menu (FIXLOG).
        check("S-068 a read-only file's row menu offers no Delete, Rename, Empty or Edit",
              tab.objectActions(["table:notes"]).delete.isEmpty && tab.objectActions(["table:notes"]).rename == nil
                  && tab.objectActions(["table:notes"]).empty.isEmpty && tab.objectActions(["view:order_totals"]).definition == nil
                  && !tab.menuSnapshot.canEditDefinition && tab.menuSnapshot.creatableKinds.isEmpty,
              "\(tab.objectActions(["table:notes"]).delete.map(\.name)) \(tab.menuSnapshot.creatableKinds)")
        tab.view = .query
        tab.query.text = "DELETE FROM notes;"
        tab.runAll()
        await tab.currentLoad?.value
        check("S-068 a read-only file refuses a write from Query", tab.query.error?.message == "“quarry_demo.sqlite” is open read only.",
              tab.query.error?.message ?? tab.query.status)
        tab.view = .content

        // Another app holding a write lock: wait up to 5 seconds, then say so.
        if let holder = try? await DatabaseClient.connect(ConnectionDetails(transport: .sqlite, file: url.path)) {
            _ = try? await holder.run("BEGIN EXCLUSIVE")
            let clock = ContinuousClock()
            let start = clock.now
            tab.refresh()
            await tab.currentLoad?.value
            await until { tab.content.load.error != nil }
            let message = tab.content.load.error?.message ?? tab.browseError?.message ?? ""
            check("S-068 a locked file waits, then says it is busy",
                  message == "“quarry_demo.sqlite” is busy. Another app is writing to it." && clock.now - start >= .seconds(4), message)
            _ = try? await holder.run("ROLLBACK")
            await holder.close()
        }
        tab.disconnect()

        // File > New SQLite File…: an empty file, open on the empty sidebar.
        let fresh = folder.appending(path: "Fresh.sqlite")
        await tab.createSQLiteFile(at: fresh, replacing: false)?.value
        await tab.currentLoad?.value
        check("S-068 New SQLite File makes an empty file and opens it",
              SQLiteFile.isSQLite(fresh) && tab.phase == .connected && tab.objects.isEmpty && tab.database == "main",
              tab.connectProblem?.message ?? "\(tab.phase) \(tab.objects.count)")
        tab.disconnect()

        // Opening a file on a Connect page uses that window.
        tab.show(saved: nil)
        tab.openFile(fresh)
        await tab.waitForConnect()
        check("S-068 Open… with a SQLite file connects this window", tab.phase == .connected && tab.connectionName == "Fresh.sqlite",
              tab.connectProblem?.message ?? "\(tab.phase)")
    }
}
