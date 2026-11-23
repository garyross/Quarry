import AppKit
import QuarryKit
import QuarryControllers

/// S-072: Database Information and Table > Maintenance on a SQLite file.
extension SelfTest {
    static func sqliteInfo(_ tab: Session, model: AppModel) async {
        guard let url = makeSQLiteFixture() else { return }
        tab.form = ConnectionDetails(transport: .sqlite, file: url.path)
        tab.connect(model: model)
        await tab.waitForConnect()
        await tab.currentLoad?.value
        let info = tab.databaseInfo
        info.reset()
        tab.showsDatabaseInfo = true
        await info.waitUntilIdle()
        let file = info.fileInfo
        check("S-072 ⌥⌘I on a SQLite file shows its size, pages and settings",
              file?.fileName == "quarry_demo.sqlite" && (file?.fileBytes ?? 0) > 0 && (file?.pageSize ?? 0) > 0
                  && (file?.pageCount ?? 0) > 0 && file?.encoding == "UTF-8" && file?.foreignKeys == true
                  && file?.version == SQLiteFile.version && file?.countsLine.hasPrefix("7 tables · 1 view") == true,
              "\(String(describing: file)) \(info.overviewError?.message ?? "")")
        check("S-072 the panel offers the file's tools",
              DatabaseInfo.Tool.tools(for: info.engine) == [.integrity, .foreignKeys, .health, .analyze, .optimize, .vacuum]
                  && DatabaseInfo.Tool.tools(for: .sqlite).allSatisfy(info.canRun) && !info.canRun(.check))

        await tab.runTool(.integrity)?.value
        check("S-072 Integrity Check finds no problems in the fixture",
              info.shown == .integrity && info.fileChecks.isEmpty && info.toolError == nil, info.toolError?.message ?? "\(info.fileChecks)")
        await tab.runTool(.foreignKeys)?.value
        check("S-072 Foreign Key Check finds no problems in the fixture", info.fileChecks.isEmpty && info.toolError == nil,
              info.toolError?.message ?? "\(info.fileChecks)")

        // A row whose parent is missing, written with foreign keys off.
        if let other = try? await DatabaseClient.connect(ConnectionDetails(transport: .sqlite, file: url.path)) {
            _ = try? await other.run("PRAGMA foreign_keys = OFF")
            _ = try? await other.run("INSERT INTO orders (id, customer_id, placed_at) VALUES (99, 404, '2026-11-20')")
            await other.close()
        }
        await tab.runTool(.foreignKeys)?.value
        check("S-072 Foreign Key Check lists a row with a missing parent, with its table",
              info.fileChecks.map(\.table) == ["orders"] && info.fileChecks.first?.message == "1 row refers to missing rows in customers (rowid 99)",
              "\(info.fileChecks)")

        await tab.runTool(.health)?.value
        let ids = info.findings.map(\.id)
        check("S-072 Health Check flags the foreign key error and order_items.product_id's missing index",
              ids == ["foreign-key-errors", "foreign-key-index"]
                  && info.findings.last?.sql == "CREATE INDEX `order_items_product_id_idx` ON `order_items` (`product_id`);",
              "\(ids) \(info.findings.last?.sql ?? "")")

        await tab.runTool(.analyze)?.value
        check("S-072 Analyze says what it did", info.fileResult == "Statistics updated for 7 tables.", info.fileResult ?? info.toolError?.message ?? "")
        await tab.runTool(.optimize)?.value
        check("S-072 Optimize runs", info.fileResult?.hasPrefix("Done.") == true, info.fileResult ?? info.toolError?.message ?? "")

        // Free pages for Vacuum to give back.
        if let other = try? await DatabaseClient.connect(ConnectionDetails(transport: .sqlite, file: url.path)) {
            _ = try? await other.run("CREATE TABLE junk AS SELECT randomblob(4000) AS b FROM events")
            _ = try? await other.run("DROP TABLE junk")
            await other.close()
        }
        await info.load("main", client: tab.client!, force: true)
        let before = info.fileInfo?.fileBytes ?? 0
        await tab.runTool(.vacuum)?.value
        check("S-072 Vacuum asks first", info.confirmingVacuum && info.running == nil
                  && info.fileInfo?.vacuumMessage.contains("give back") == true, info.fileInfo?.vacuumMessage ?? "")
        info.confirmingVacuum = false
        await tab.confirmVacuum()?.value
        let after = info.fileInfo
        check("S-072 Vacuum gives back the free pages and says how much",
              after?.freePages == 0 && (after?.fileBytes ?? .max) < before
                  && info.fileResult == SQLiteFileInfo.vacuumResult("quarry_demo.sqlite", before: before, after: after?.fileBytes ?? 0),
              "\(before) → \(after?.fileBytes ?? 0): \(info.fileResult ?? info.toolError?.message ?? "")")

        // Table > Maintenance: Check and Analyze; the server-only ones gray out.
        tab.selectedObjectID = "table:orders"
        await tab.currentLoad?.value
        check("S-072 Table > Maintenance offers Check and Analyze on a SQLite table",
              tab.tableOperationTitle(.check) == "Check Table" && tab.tableOperationTitle(.analyze) == "Analyze Table"
                  && [.repair, .optimize, .flush, .checksum].allSatisfy { tab.tableOperationTitle($0) == nil })
        await tab.runTableOperation(.check)?.value
        check("S-072 Check Table runs integrity_check on the table",
              tab.alert?.title == "Check \u{201C}orders\u{201D}" && tab.alert?.message == "OK",
              tab.alert?.message ?? "no alert")
        tab.alert = nil
        await sqliteMaintenanceMenu(tab)

        // Read only: the tools that write gray out.
        tab.showsDatabaseInfo = false
        tab.disconnect()
        tab.form = ConnectionDetails(transport: .sqlite, file: url.path, readOnly: true)
        tab.connect(model: model)
        await tab.waitForConnect()
        await tab.currentLoad?.value
        info.reset()
        tab.showsDatabaseInfo = true
        await info.waitUntilIdle()
        check("S-072 a read-only file grays out Vacuum, Analyze and Optimize",
              info.fileInfo?.isReadOnly == true && info.canRun(.integrity) && info.canRun(.health)
                  && !info.canRun(.vacuum) && !info.canRun(.analyze) && !info.canRun(.optimize)
                  && !tab.menuSnapshot.runnableTools.contains(.vacuum) && tab.tableOperationTitle(.analyze) == nil,
              "\(info.fileInfo?.isReadOnly ?? false) \(tab.menuSnapshot.runnableTools) \(tab.tableOperationTitle(.analyze) ?? "nil")")
        tab.showsDatabaseInfo = false
        tab.disconnect()
    }

    /// The Table > Maintenance submenu on a SQLite window: Check and Analyze on, the rest grayed with why.
    static func sqliteMaintenanceMenu(_ tab: Session) async {
        tab.window?.makeKeyAndOrderFront(nil)
        await until { MenuState.shared.active === tab }
        MenuState.shared.activate(tab)
        try? await Task.sleep(for: .milliseconds(300))
        let walked = walkMenuBar().filter { $0.menu == "Table" }
        func enabled(_ title: String) -> Bool? { walked.first { $0.title == title }?.isEnabled }
        check("S-072 the Maintenance menu keeps Check and Analyze on and grays the server-only items",
              enabled("Check Table") == true && enabled("Analyze Table") == true && enabled("Repair Table") == false
                  && enabled("Checksum Table") == false,
              walked.filter { $0.title.hasSuffix("Table") }.map { "\($0.title) \($0.isEnabled)" }.joined(separator: ", "))
    }
}
