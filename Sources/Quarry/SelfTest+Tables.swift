import AppKit
import QuarryKit
import SwiftData

/// Self-test: New, duplicate, rename and delete databases and tables; table info, create statements and maintenance (S-018, S-019, S-021, S-022, S-027 to S-029).
extension SelfTest {
    // MARK: S-018

    static func newDatabase(session: Session) async {
        let name = "quarry_selftest_new"
        guard let client = session.client else { return check("S-018 connected", false) }
        _ = try? await client.run("DROP DATABASE IF EXISTS " + SQLQuote.identifier(name))
        await session.loadDatabases(select: nil)

        session.requestNewDatabase()
        guard let creator = session.newDatabase else { return check("S-018 ⇧⌘N opens New Database", false) }
        await until { creator.catalog != nil || creator.loadError != nil }
        check("S-018 the sheet loads the server's character sets, UTF-8 first",
              creator.catalog?.charsets.first?.name == "utf8mb4", creator.loadError?.message ?? "")
        check("S-018 the defaults name the server's",
              creator.defaultCharsetTitle == "Server Default (utf8mb4)"
                  && creator.collations.allSatisfy { $0.hasPrefix("utf8mb4_") } && !creator.collations.isEmpty,
              creator.defaultCharsetTitle)

        creator.name = "quarry_demo"
        check("S-018 an existing name is refused", creator.nameProblem != nil && !creator.canCreate)

        creator.collation = "utf8mb4_bin"
        creator.charset = "latin1"
        check("S-018 the collation list follows the chosen character set",
              creator.collation == nil && creator.collations.contains("latin1_swedish_ci")
                  && creator.collations.allSatisfy { $0.hasPrefix("latin1_") }
                  && creator.defaultCollationTitle == "Default (latin1_swedish_ci)",
              "\(creator.collations.prefix(3)) \(creator.defaultCollationTitle)")

        // A collation of another character set: the server refuses, the sheet stays with its message.
        creator.name = name
        creator.collation = "utf8mb4_bin"
        await session.createDatabase()?.value
        check("S-018 a server error stays in the sheet", session.newDatabase === creator && creator.createError != nil)

        creator.collation = "latin1_bin"
        await session.createDatabase()?.value
        let schema = try? await client.run(
            "SELECT DEFAULT_CHARACTER_SET_NAME AS cs, DEFAULT_COLLATION_NAME AS co FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = "
                + SQLQuote.mysqlLiteral(name))
        check("S-018 Create makes the database with the chosen character set and collation",
              schema?.string(0, "cs") == "latin1" && schema?.string(0, "co") == "latin1_bin",
              "\(schema?.string(0, "cs") ?? "none") \(schema?.string(0, "co") ?? "")")
        check("S-018 the new database is selected and listed",
              session.newDatabase == nil && session.database == name && session.databases.contains(name)
                  && session.browseError == nil && session.objects.isEmpty)

        _ = try? await client.run("DROP DATABASE IF EXISTS " + SQLQuote.identifier(name))
        session.database = "quarry_demo"
        await session.currentLoad?.value
        await session.loadDatabases(select: nil)
    }

    // MARK: S-022

    static func tableActions(model: AppModel, session: Session) async {
        guard let client = session.client else { return check("S-022 connected", false) }
        let copy = "quarry_st_orders", renamed = "quarry_st_moved", bare = "quarry_st_customers"
        for name in [copy, renamed, bare] {
            _ = try? await client.run("DROP TABLE IF EXISTS `quarry_demo`." + SQLQuote.identifier(name))
        }
        session.database = "quarry_demo"
        await session.currentLoad?.value
        let orders = DBObject(name: "orders", kind: .table).id

        session.requestDuplicateTable([orders])
        guard let duplicator = session.tableDuplicator else { return check("S-022 Duplicate Table opens its sheet", false) }
        check("S-022 the sheet suggests orders_copy", duplicator.name == "orders_copy", duplicator.name)
        duplicator.name = "order_totals"
        check("S-022 a name that exists is refused", duplicator.nameProblem != nil && !duplicator.canRun)
        duplicator.name = copy
        await session.runDuplicateTable()?.value
        let counts = try? await client.run("SELECT (SELECT COUNT(*) FROM `quarry_demo`.`orders`) AS a, "
            + "(SELECT COUNT(*) FROM `quarry_demo`.\(SQLQuote.identifier(copy))) AS b")
        let keys = try? await client.run("SELECT COUNT(*) AS n FROM information_schema.REFERENTIAL_CONSTRAINTS "
            + "WHERE CONSTRAINT_SCHEMA = 'quarry_demo' AND TABLE_NAME = " + SQLQuote.mysqlLiteral(copy))
        check("S-022 Duplicate copies the rows and foreign keys, and selects the copy",
              session.tableDuplicator == nil && counts?.string(0, "a") == counts?.string(0, "b")
                  && counts?.string(0, "a") != "0" && keys?.string(0, "n") != "0" && session.selectedObject?.name == copy,
              "\(counts?.string(0, "a") ?? "-") \(counts?.string(0, "b") ?? "-") keys \(keys?.string(0, "n") ?? "-") \(session.selectedObject?.name ?? "none")")

        session.requestDuplicateTable([DBObject(name: "customers", kind: .table).id])
        session.tableDuplicator?.name = bare
        session.tableDuplicator?.withRows = false
        await session.runDuplicateTable()?.value
        let bareCount = try? await client.rowCount(of: bare, in: "quarry_demo")
        check("S-022 Duplicate without rows makes an empty copy", bareCount == 0 && session.selectedObject?.name == bare,
              "\(bareCount ?? -1)")

        session.selectedObjectID = DBObject(name: copy, kind: .table).id
        await session.currentLoad?.value
        session.requestRenameTable()
        check("S-022 Rename edits the name in the sidebar", session.renamingObjectID == session.selectedObjectID
                  && session.renameText == copy)
        session.renameText = "orders"
        session.commitRename()
        check("S-022 Rename to a taken name says why and keeps the old name",
              session.alert != nil && session.selectedObject?.name == copy)
        session.alert = nil
        session.requestRenameTable()
        session.renameText = renamed
        await session.commitRename()?.value
        check("S-022 Rename keeps the table selected under its new name",
              session.selectedObject?.name == renamed && !session.objects.contains { $0.name == copy },
              session.selectedObject?.name ?? "none")

        session.requestEmptyTables()
        check("S-022 Empty asks, naming the table", session.alert?.tableEdit?.title == "Empty table \u{201C}\(renamed)\u{201D}?",
              session.alert?.tableEdit?.title ?? "none")
        await session.confirmTableEdit()?.value
        let left = try? await client.rowCount(of: renamed, in: "quarry_demo")
        check("S-022 Empty deletes every row", left == 0 && session.alert == nil, "\(left ?? -1)")

        // `orders` is referenced by order_items, so TRUNCATE is refused; only try when that holds.
        let referenced = try? await client.run("SELECT COUNT(*) AS n FROM information_schema.REFERENTIAL_CONSTRAINTS "
            + "WHERE CONSTRAINT_SCHEMA = 'quarry_demo' AND REFERENCED_TABLE_NAME = 'orders' AND TABLE_NAME = 'order_items'")
        if referenced?.string(0, "n") != "0" {
            session.requestEmptyTables([orders])
            await session.confirmTableEdit()?.value
            check("S-022 a foreign-key refusal points at Ignore foreign keys",
                  session.alert?.message.contains("Ignore foreign keys") == true,
                  session.alert?.message ?? "no failure")
            session.alert = nil
        }

        let both: Set = [DBObject(name: renamed, kind: .table).id, DBObject(name: bare, kind: .table).id]
        session.sidebarSelection = both
        check("S-022 the menu names the count", session.menuSnapshot.deleteTitle == "Delete 2 Tables…"
                  && !session.menuSnapshot.canRenameTable, session.menuSnapshot.deleteTitle)
        session.requestDeleteTables()
        check("S-022 Delete of several names the count", session.alert?.tableEdit?.title == "Delete 2 tables?",
              session.alert?.tableEdit?.title ?? "none")
        await session.confirmTableEdit()?.value
        check("S-022 Delete drops every selected table",
              !session.objects.contains { $0.name == renamed || $0.name == bare } && session.selectedObjectID == nil
                  && session.sidebarSelection.isEmpty && session.alert == nil,
              session.alert?.message ?? "")
        session.view = .content
    }

    // MARK: S-027

    static func tableInfoChanges(session: Session) async {
        guard let client = session.client else { return check("S-027 connected", false) }
        session.database = "quarry_demo"
        await session.currentLoad?.value
        let table = "quarry_selftest_info"
        let qualified = "`quarry_demo`." + SQLQuote.identifier(table)
        _ = try? await client.run("DROP TABLE IF EXISTS " + qualified)
        _ = try? await client.run("CREATE TABLE \(qualified) (id INT AUTO_INCREMENT PRIMARY KEY, note VARCHAR(20)) "
            + "ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_general_ci")
        _ = try? await client.run("INSERT INTO \(qualified) (id, note) VALUES (1, 'a'), (2, 'b'), (3, 'c')")
        _ = try? await client.run("DELETE FROM \(qualified) WHERE id = 3")
        try? await session.loadObjects(client, "quarry_demo")
        session.view = .info
        session.selectedObjectID = "table:\(table)"
        await session.currentLoad?.value
        let info = session.info
        func live(_ column: String) async -> String? {
            let result = try? await client.run("SELECT \(column) AS v FROM information_schema.TABLES "
                + "WHERE TABLE_SCHEMA = 'quarry_demo' AND TABLE_NAME = " + SQLQuote.mysqlLiteral(table))
            return result?.string(0, "v")
        }

        check("S-027 Info shows the engine, collation and auto-increment value", info.canEdit
                  && info.status?.engine == "InnoDB" && info.status?.collation == "utf8mb4_general_ci"
                  && info.charset == "utf8mb4" && info.status?.autoIncrement == 4 && info.autoIncrementText == "4"
                  && info.engineChoices.contains("Aria") && info.collationChoices.contains("utf8mb4_bin")
                  && info.createStatement.hasPrefix("CREATE TABLE `\(table)`"),
              "\(info.status.map { "\($0.engine) \($0.collation) \($0.autoIncrement ?? -1)" } ?? "none") "
                  + (info.load.error?.message ?? ""))
        check("S-027 the Table menu offers Reset Auto Increment", session.menuSnapshot.canResetAutoIncrement)

        session.resetAutoIncrement()
        await session.currentLoad?.value
        check("S-027 Resetting AUTO_INCREMENT shows the new value", info.status?.autoIncrement == 3
                  && info.autoIncrementText == "3" && info.editError == nil,
              "\(info.status?.autoIncrement ?? -1) \(info.editError?.message ?? "")")
        info.autoIncrementText = "1,000"
        session.commitAutoIncrement()
        await session.currentLoad?.value
        let typed = await live("AUTO_INCREMENT")
        check("S-027 a typed auto-increment value is set", info.status?.autoIncrement == 1000 && typed == "1000",
              "\(info.autoIncrementText) \(typed ?? "")")
        info.autoIncrementText = "soon"
        session.commitAutoIncrement()
        check("S-027 text that isn't a number goes back", info.autoIncrementText == "1000" && !info.isChanging)

        info.comment = "Self-test's notes"
        session.commitTableComment()
        await session.currentLoad?.value
        let comment = await live("TABLE_COMMENT")
        check("S-027 Comment saves on Return", info.status?.comment == "Self-test's notes"
                  && comment == "Self-test's notes", comment ?? "")

        session.setTableCollation("utf8mb4_bin")
        await session.currentLoad?.value
        check("S-027 Collation changes the table's default", info.status?.collation == "utf8mb4_bin"
                  && info.createStatement.contains("utf8mb4_bin"), info.status?.collation ?? "")
        session.setTableCharset("latin1")
        await session.currentLoad?.value
        check("S-027 Character Set changes it and its collation", info.charset == "latin1"
                  && info.status?.collation.hasPrefix("latin1_") == true, info.status?.collation ?? "")
        session.setTableCollation("quarry_no_such_collation")
        await session.currentLoad?.value
        check("S-027 a server error shows and the menus go back", info.editError != nil
                  && info.status?.collation.hasPrefix("latin1_") == true && info.canEdit,
              info.editError?.message ?? "no error")

        session.requestTableEngine("Aria")
        check("S-027 changing the engine asks first", info.pendingEngine == "Aria" && info.status?.engine == "InnoDB")
        session.confirmTableEngine()
        await session.currentLoad?.value
        let engine = await live("ENGINE")
        check("S-027 the engine changes after the alert", info.status?.engine == "Aria"
                  && engine == "Aria" && info.editError == nil, info.editError?.message ?? "")

        session.selectedObjectID = "view:order_totals"
        await session.currentLoad?.value
        check("S-027 a view's Info can't be changed", !info.canEdit && info.kind == .view
                  && !session.menuSnapshot.canResetAutoIncrement && info.createStatement.contains("VIEW"))

        _ = try? await client.run("DROP TABLE IF EXISTS " + qualified)
        session.view = .content
        session.selectedObjectID = nil
        try? await session.loadObjects(client, "quarry_demo")
    }

    // MARK: S-029

    static func tableMaintenance(session: Session) async {
        guard session.client != nil else { return check("S-029 connected", false) }
        session.database = "quarry_demo"
        await session.currentLoad?.value
        session.selectedObjectID = "table:customers"
        await session.currentLoad?.value
        session.sidebarSelection = ["table:customers", "table:orders", "view:order_totals"]
        // The menu bar follows MenuState's snapshot once the window sees the change.
        await until { MenuState.shared.snapshot.tableOperationTitles[.check] == "Check 3 Items" }
        let titles = MenuState.shared.snapshot.tableOperationTitles
        let item = NSApp.mainMenu?.items.lazy.compactMap { $0.submenu?.items.first { $0.title == "Maintenance" } }.first
        check("S-029 Table > Maintenance lists the six operations", item?.submenu?.items.count == 6 && titles.count == 6
                  && titles[.check] == "Check 3 Items" && titles[.checksum] == "Checksum 2 Tables",
              "\(item?.submenu?.items.count ?? 0) items, \(titles.values.sorted())")
        check("S-029 Check works on views, the others skip them",
              session.tableOperationTitle(.check) == "Check 3 Items" && session.tableOperationTitle(.repair) == "Repair 2 Tables"
              && session.tableOperationTitle(.check, ["view:order_totals"]) == "Check View"
              && session.tableOperationTitle(.optimize, ["view:order_totals"]) == nil)

        let task = session.runTableOperation(.check)
        check("S-029 the menu is off while it runs", session.menuSnapshot.tableOperationTitles.isEmpty)
        await task?.value
        let checked = session.alert
        check("S-029 the Check alert lists each table's status",
              checked?.title == "Check 3 Tables" && checked?.message.hasPrefix("All 3 tables are OK.") == true
              && checked?.message.contains("customers: OK") == true && checked?.message.contains("orders: OK") == true
              && checked?.message.contains("order_totals: OK") == true, checked?.message ?? "no alert")
        session.alert = nil

        for operation in [TableOperation.repair, .analyze, .optimize, .flush] {
            await session.runTableOperation(operation)?.value
            let result = session.alert
            check("S-029 \(operation.verb) lists each table", result?.title == "\(operation.verb) 2 Tables"
                      && result?.message.hasPrefix("All 2 tables are OK.") == true
                      && result?.message.contains("customers: ") == true && result?.message.contains("orders: ") == true
                      && result?.message.contains("order_totals") == false, result?.message ?? "no alert")
            session.alert = nil
        }

        await session.runTableOperation(.checksum, ["table:customers"])?.value
        let sum = session.alert
        check("S-029 Checksum shows one table's number", sum?.title == "Checksum “customers”"
                  && Int(sum?.message ?? "") != nil, sum?.message ?? "no alert")
        session.alert = nil

        session.objects.append(DBObject(name: "quarry_no_such_table", kind: .table))
        await session.runTableOperation(.analyze, ["table:quarry_no_such_table"])?.value
        let missing = session.alert?.message ?? "no alert"
        check("S-029 a missing table shows the server's words", missing.localizedCaseInsensitiveContains("exist"), missing)
        session.alert = nil
        session.sidebarSelection = ["table:customers"]
        if let client = session.client { try? await session.loadObjects(client, "quarry_demo") }
    }

    // MARK: S-028

    static func createStatements(session: Session) async {
        guard session.client != nil else { return check("S-028 connected", false) }
        session.database = "quarry_demo"
        await session.currentLoad?.value
        session.view = .content
        session.selectedObjectID = "table:orders"
        await session.currentLoad?.value

        func item(_ title: String) -> NSMenuItem? { menuItems { $0.title == title }.first }
        let copyItem = item("Copy Create Statement"), showItem = item("Show Create Statement…")
        check("S-028 Table menu has Copy Create Statement (⇧⌘C) and Show Create Statement… (⌃⌘C)",
              copyItem?.keyEquivalent.lowercased() == "c" && copyItem?.keyEquivalentModifierMask == [.command, .shift]
              && showItem?.keyEquivalent == "c" && showItem?.keyEquivalentModifierMask == [.command, .control],
              "\(copyItem?.keyEquivalent ?? "-") \(copyItem?.keyEquivalentModifierMask.rawValue ?? 0)")
        check("S-028 the commands are on for a selected table", session.menuSnapshot.canShowCreateStatement)

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer { if let saved { Session.copyToPasteboard(saved) } }
        pasteboard.clearContents()
        await session.copyCreateStatement()?.value
        let copied = pasteboard.string(forType: .string) ?? ""
        check("S-028 ⇧⌘C copies it without opening the sheet",
              copied.hasPrefix("CREATE TABLE `orders`") && copied.hasSuffix(";") && session.createStatementSheet == nil,
              String(copied.prefix(60)))

        session.sidebarSelection = ["table:orders", "view:order_totals", "procedure:customer_orders"]
        await session.copyCreateStatement()?.value
        let several = pasteboard.string(forType: .string) ?? ""
        check("S-028 several objects each get a header; a procedure sits between DELIMITER lines",
              several.hasPrefix("-- Create statement for table `orders`\nCREATE TABLE")
              && several.contains("-- Create statement for view `order_totals`\nCREATE ")
              && several.contains("-- Create statement for procedure `customer_orders`\nDELIMITER ;;\nCREATE ")
              && several.hasSuffix(";;\nDELIMITER ;"), String(several.suffix(80)))

        let load = session.requestShowCreateStatement(["function:order_count"])
        check("S-028 the sheet opens with its title", session.createStatementSheet?.title == "Create Statement for Function “order_count”",
              session.createStatementSheet?.title ?? "no sheet")
        check("S-028 the menu commands are off while it is open", !session.menuSnapshot.canShowCreateStatement)
        await load?.value
        let sheet = session.createStatementSheet
        check("S-028 the sheet shows the function's statement",
              sheet?.isLoading == false && sheet?.text.contains("FUNCTION `order_count`") == true && sheet?.fileName == "order_count.sql",
              String(sheet?.text.prefix(60) ?? ""))
        sheet?.copy()
        check("S-028 Copy in the sheet copies it and says so",
              pasteboard.string(forType: .string) == sheet?.text && sheet?.copied == true)
        session.createStatementSheet = nil

        session.objects.append(DBObject(name: "quarry_no_such_table", kind: .table))
        await session.requestShowCreateStatement(["table:quarry_no_such_table"])?.value
        check("S-028 a server error closes the sheet and shows an alert",
              session.createStatementSheet == nil && session.alert?.title == "Couldn’t get the create statement",
              session.alert?.message ?? "no alert")
        session.alert = nil
        session.sidebarSelection = ["table:orders"]
        if let client = session.client { try? await session.loadObjects(client, "quarry_demo") }
    }

    // MARK: S-021

    static func newTable(session: Session) async {
        let name = "quarry_selftest_table"
        guard let client = session.client else { return check("S-021 connected", false) }
        session.database = "quarry_demo"
        await session.currentLoad?.value
        _ = try? await client.run("DROP TABLE IF EXISTS `quarry_demo`." + SQLQuote.identifier(name))

        session.requestNewTable()
        guard let creator = session.newTable else { return check("S-021 ⌥⌘N opens New Table", false) }
        await until { !creator.isLoading }
        check("S-021 the sheet loads engines and the database's defaults",
              creator.defaults?.engines.contains("InnoDB") == true && creator.defaultEngineTitle.hasPrefix("Default (")
                  && creator.defaultCharsetTitle.hasPrefix("Database Default (") && !creator.collations.isEmpty,
              "\(creator.defaultEngineTitle) \(creator.defaultCharsetTitle) \(creator.loadError?.message ?? "")")

        creator.name = "order_totals"
        check("S-021 a table or view name that exists is refused", creator.nameProblem != nil && !creator.canCreate)

        creator.name = name
        creator.charset = "latin1"
        creator.collation = "utf8mb4_bin"
        await session.createTable()?.value
        check("S-021 a server error stays in the sheet", session.newTable === creator && creator.createError != nil)

        creator.collation = "latin1_bin"
        creator.engine = "Aria"
        await session.createTable()?.value
        let status = try? await client.run(
            "SELECT ENGINE AS e, TABLE_COLLATION AS co FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'quarry_demo' AND TABLE_NAME = "
                + SQLQuote.mysqlLiteral(name))
        check("S-021 Create uses the chosen engine and collation",
              status?.string(0, "e") == "Aria" && status?.string(0, "co") == "latin1_bin",
              "\(status?.string(0, "e") ?? "none") \(status?.string(0, "co") ?? "")")
        let column = try? await client.run(
            "SELECT COLUMN_TYPE AS t, EXTRA AS x, COLUMN_KEY AS k FROM information_schema.COLUMNS "
                + "WHERE TABLE_SCHEMA = 'quarry_demo' AND TABLE_NAME = " + SQLQuote.mysqlLiteral(name))
        check("S-021 the new table has an id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY",
              column?.rows.count == 1 && column?.string(0, "t")?.hasPrefix("int") == true
                  && column?.string(0, "t")?.contains("unsigned") == true
                  && column?.string(0, "x") == "auto_increment" && column?.string(0, "k") == "PRI",
              "\(column?.string(0, "t") ?? "none") \(column?.string(0, "x") ?? "") \(column?.string(0, "k") ?? "")")
        check("S-021 the new table is selected on Structure",
              session.newTable == nil && session.selectedObject?.name == name && session.view == .structure
                  && session.structure.fields.rows.count == 1,
              "\(session.selectedObject?.name ?? "none") \(session.view) \(session.structure.fields.rows.count)")

        _ = try? await client.run("DROP TABLE IF EXISTS `quarry_demo`." + SQLQuote.identifier(name))
        session.view = .content
        session.selectedObjectID = nil
        try? await session.loadObjects(client, "quarry_demo")
    }

    // MARK: S-019

    static func databaseActions(model: AppModel, session: Session) async {
        let copy = "quarry_selftest_copy", moved = "quarry_selftest_moved", bare = "quarry_selftest_bare"
        guard let client = session.client else { return check("S-019 connected", false) }
        for name in [copy, moved, bare] { _ = try? await client.run("DROP DATABASE IF EXISTS " + SQLQuote.identifier(name)) }
        await session.loadDatabases(select: "quarry_demo")

        // System databases are protected.
        session.database = "mysql"
        await session.currentLoad?.value
        check("S-019 mysql can't be renamed, changed or deleted", session.editableDatabase == nil
              && !session.menuSnapshot.canEditDatabase && session.menuSnapshot.canDuplicateDatabase)
        session.database = "quarry_demo"
        await session.currentLoad?.value

        // Duplicate with rows.
        session.requestDatabaseEditor(.duplicate)
        guard let editor = session.databaseEditor else { return check("S-019 ⌥⇧⌘N opens Duplicate Database", false) }
        check("S-019 Duplicate suggests a free name", editor.name == "quarry_demo_copy" && editor.source == "quarry_demo")
        editor.name = "quarry_empty"
        check("S-019 an existing name is refused", editor.nameProblem != nil && !editor.canRun)
        editor.name = copy
        await session.runDatabaseEditor()?.value
        let demoObjects = Set(((try? await client.objects(in: "quarry_demo")) ?? []).map(\.id))
        let copyObjects = Set(((try? await client.objects(in: copy)) ?? []).map(\.id))
        let rows = try? await client.rowCount(of: "events", in: copy)
        let copyTriggers = try? await client.run(
            "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = " + SQLQuote.mysqlLiteral(copy))
        check("S-019 Duplicate copies tables, rows, views, triggers and routines",
              session.databaseEditor == nil && copyObjects == demoObjects && rows == 100_000
                  && copyTriggers?.rows.first?.first?.plainText == "1",
              "\(editor.error?.message ?? "") \(editor.problems) \(copyObjects.count)/\(demoObjects.count) rows \(rows ?? -1)")
        let view = try? await client.createStatement(of: DBObject(name: "order_totals", kind: .view), in: copy)
        // The server leaves out the database name when it is the current one.
        check("S-019 the copied view reads the copied tables", view?.contains("`orders`") == true
              && view?.contains("`quarry_demo`.") == false, view ?? "")
        check("S-019 the copy is selected", session.database == copy && session.objects.count == demoObjects.count)

        // Duplicate without rows.
        session.requestDatabaseEditor(.duplicate)
        session.databaseEditor?.name = bare
        session.databaseEditor?.withRows = false
        await session.runDatabaseEditor()?.value
        let bareRows = try? await client.rowCount(of: "orders", in: bare)
        let bareCreate = try? await client.createStatement(of: DBObject(name: "orders", kind: .table), in: bare)
        check("S-019 without rows, the tables are empty and count from 1",
              bareRows == 0 && bareCreate?.contains("AUTO_INCREMENT=") == false, bareCreate ?? "")

        // Rename the copy; a favorite on it follows.
        session.database = copy
        await session.currentLoad?.value
        if !session.isFavoriteDatabase { session.toggleFavoriteDatabase() }
        session.requestDatabaseEditor(.rename)
        guard let renamer = session.databaseEditor, renamer.mode == .rename else {
            return check("S-019 ⌥⇧⌘R opens Rename Database", false)
        }
        check("S-019 Rename needs a new name", !renamer.canRun)
        renamer.name = moved
        await session.runDatabaseEditor()?.value
        await session.loadDatabases(select: nil)
        let movedObjects = Set(((try? await client.objects(in: moved)) ?? []).map(\.id))
        let movedTriggers = try? await client.run(
            "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = " + SQLQuote.mysqlLiteral(moved))
        let movedRows = try? await client.rowCount(of: "events", in: moved)
        check("S-019 Rename moves every table, view, trigger and routine",
              movedObjects == demoObjects && movedRows == 100_000 && movedTriggers?.rows.first?.first?.plainText == "1",
              "\(renamer.error?.message ?? "") \(renamer.problems) \(movedObjects.count)/\(demoObjects.count)")
        check("S-019 the old name is gone and the new one is selected",
              !session.databases.contains(copy) && session.database == moved && session.databaseEditor == nil)
        check("S-019 the favorite follows the rename", session.isFavoriteDatabase
              && !session.favoriteDatabases.contains(copy))

        // Change Character Set.
        session.requestDatabaseEditor(.alter)
        guard let alter = session.databaseEditor, alter.mode == .alter else {
            return check("S-019 ⌥⇧⌘C opens Change Character Set", false)
        }
        await until { alter.catalog != nil || alter.error != nil }
        check("S-019 Change Character Set starts on the database's own",
              alter.charset == "utf8mb4" && alter.collation == "utf8mb4_unicode_ci",
              "\(alter.charset ?? "nil") \(alter.collation ?? "nil") \(alter.error?.message ?? "")")
        alter.charset = "latin1"
        await session.runDatabaseEditor()?.value
        let options = try? await client.options(of: moved)
        check("S-019 Change runs ALTER DATABASE", options?.charset == "latin1" && options?.collation == "latin1_swedish_ci"
              && session.databaseEditor == nil, "\(String(describing: options))")

        // Delete asks first and names the database.
        session.requestDeleteDatabase()
        check("S-019 Delete asks, naming the database", session.alert?.databaseToDelete == moved)
        await session.confirmDeleteDatabase()?.value
        check("S-019 Delete drops it and shows Choose a Database",
              !session.databases.contains(moved) && session.database == nil && session.alert == nil)
        check("S-019 its favorite goes too", !model.favoriteNames(on: session.connectedDetails).contains(moved))

        _ = try? await client.run("DROP DATABASE IF EXISTS " + SQLQuote.identifier(bare))
        session.database = "quarry_demo"
        await session.currentLoad?.value
        await session.loadDatabases(select: nil)
    }
}
