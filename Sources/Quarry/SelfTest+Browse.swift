import AppKit
import QuarryKit
import SwiftData

/// Self-test: Browsing databases and objects, Go to Database, tabs, Back and Forward, Database Information (S-003 to S-008, S-020, S-037, S-038, S-059).
extension SelfTest {
    // MARK: S-003 – S-006, S-008

    static func browsing(session: Session) async {
        let clock = ContinuousClock()
        session.database = "quarry_legacy"
        await session.currentLoad?.value
        check("S-003 switching database lists its tables", session.objects.map(\.name) == ["counters", "notes", "visits"])
        var start = clock.now
        session.database = "quarry_demo"
        await session.currentLoad?.value
        check("S-003 the list reloads in under 1 s", clock.now - start < .seconds(1))
        let kinds = Set(session.objects.map(\.kind))
        check("S-003 tables, views and routines are listed", kinds == Set(ObjectKind.allCases), "\(kinds)")

        session.objectFilter = "ord"
        check("S-004 \"ord\" leaves the matching tables, view and routines",
              Set(session.visibleObjects.map(\.name)) == ["orders", "order_items", "order_totals", "customer_orders", "order_count"],
              "\(session.visibleObjects.map(\.name))")
        session.objectFilter = ""

        session.view = .content
        session.selectedObjectID = "table:customers"
        await session.currentLoad?.value
        check("S-005 customers shows its 10 rows", session.content.grid.rows.count == 10 && session.content.paging.label == "Rows 1–10 of 10",
              session.content.paging.label)
        let email = session.content.grid.columns.firstIndex { $0.title == "email" }
        check("S-005 NULL stays NULL", email.map { session.content.grid.rows[3][$0] == .null } == true)
        session.sortContent(by: "name", ascending: false)
        await session.currentLoad?.value
        check("S-005 a header click sorts on the server", session.content.grid.rows.first?[1] == .text("Yukihiro Matsumoto"))

        let monitor = MainThreadMonitor()
        start = clock.now
        session.selectedObjectID = "table:events"
        await session.currentLoad?.value
        let stall = monitor.stop()
        check("S-005 100 000 rows open a page at a time", session.content.paging.label == "Rows 1–1,000 of 100,000",
              session.content.paging.label)
        check("S-005 the first page loads in under 2 s", clock.now - start < .seconds(2))
        check("S-005 the main thread never stalls over 100 ms", stall < .milliseconds(100), "\(stall)")
        try? await Task.sleep(for: .seconds(0.3))
        check("S-005 on page 1 the menu bar's Previous Page is off", menuItem("Previous Page")?.isEnabled == false)
        session.movePage(by: 1)
        await session.currentLoad?.value
        check("S-005 the next page starts at row 1,001", session.content.paging.label == "Rows 1,001–2,000 of 100,000")
        // The commands observe MenuState themselves; the real menu must follow.
        try? await Task.sleep(for: .seconds(0.3))
        check("S-005 on page 2 the menu bar's Previous Page is on", menuItem("Previous Page")?.isEnabled == true)

        session.view = .structure
        session.selectedObjectID = "table:orders"
        await session.currentLoad?.value
        check("S-006 orders has 6 fields", session.structure.fields.rows.count == 6)
        check("S-006 and its indexes", Set(session.structure.indexes.rows.compactMap { $0.first?.plainText }) == ["PRIMARY", "fk_orders_customer"],
              "\(session.structure.indexes.rows.compactMap { $0.first?.plainText })")

        for view in DetailView.allCases where view != .query {
            session.view = view
            await session.currentLoad?.value
            // The menu bar follows on SwiftUI's next update (WindowRoot's onChange), not at once.
            await until { MenuState.shared.snapshot.view == view }
            check("S-008 \(view.title) keeps the selection", session.selectedObjectID == "table:orders"
                  && MenuState.shared.snapshot.view == view, "menu shows \(MenuState.shared.snapshot.view)")
        }
        check("S-008 Foreign Keys lists fk_orders_customer", session.foreignKeys.grid.rows.first?.first == .text("fk_orders_customer"))
        check("S-008 Triggers lists orders_before_update", session.triggers.grid.rows.first?.first == .text("orders_before_update"))
        check("S-008 Info shows the create statement", session.info.createStatement.hasPrefix("CREATE TABLE `orders`"))
    }


    // MARK: S-038

    static func visitHistory(session: Session) async {
        let back = menuItem("Back")
        check("S-038 View > Back is ⌃⌥← and Forward ⌃⌥→",
              back?.keyEquivalent == String(UnicodeScalar(NSLeftArrowFunctionKey)!) && back?.keyEquivalentModifierMask == [.control, .option]
                && menuItem("Forward")?.keyEquivalent == String(UnicodeScalar(NSRightArrowFunctionKey)!),
              "\(back?.keyEquivalent.unicodeScalars.map(\.value) ?? []) \(back?.keyEquivalentModifierMask.rawValue ?? 0)")
        session.database = "quarry_demo"
        await session.currentLoad?.value
        session.view = .content
        session.selectedObjectID = "table:customers"
        await session.currentLoad?.value
        session.history.removeAll()
        session.sortContent(by: "id", ascending: false)
        await session.currentLoad?.value
        session.selectedObjectID = "table:products"
        await session.currentLoad?.value
        session.view = .structure
        await session.currentLoad?.value
        check("S-038 opening a table records the one left; a view change does not",
              session.history.back.map(\.objectID) == ["table:customers"], "\(session.history.back.map(\.objectID))")
        session.database = "quarry_legacy"
        await session.currentLoad?.value
        session.selectedObjectID = session.objects.first(where: { $0.kind == .table })?.id
        await session.currentLoad?.value
        check("S-038 a database with nothing open gives way to its first table",
              session.history.back.map { "\($0.database)/\($0.objectID ?? "-")" } == ["quarry_demo/table:customers", "quarry_demo/table:products"],
              "\(session.history.back.map { "\($0.database)/\($0.objectID ?? "-")" })")
        await session.goBack()?.value
        check("S-038 Back returns to the other database's table on the view it had",
              session.database == "quarry_demo" && session.selectedObjectID == "table:products" && session.view == .structure,
              "\(session.database ?? "nil") \(session.selectedObjectID ?? "nil") \(session.view)")
        await session.goBack()?.value
        check("S-038 Back again restores Content's sort",
              session.selectedObjectID == "table:customers" && session.view == .content
                && session.content.sortColumn == "id" && !session.content.ascending,
              "\(session.selectedObjectID ?? "nil") \(session.view) \(session.content.sortColumn ?? "none")")
        check("S-038 Back records nothing new", session.history.back.isEmpty && session.history.forward.count == 2)
        await session.goForward()?.value
        session.selectedObjectID = "table:orders"
        await session.currentLoad?.value
        check("S-038 a new visit drops the places ahead", !session.history.canGoForward && session.history.back.count == 2,
              "\(session.history.back.count) back, \(session.history.forward.count) ahead")
        // The tabs check expects order_items on Content, sorted by order_id, with no history.
        session.selectedObjectID = "table:order_items"
        await session.currentLoad?.value
        session.sortContent(by: "order_id", ascending: true)
        await session.currentLoad?.value
        session.history.removeAll()
    }

    // MARK: S-037

    static func tabs(session: Session) async {
        let newTab = menuItem("New Connection Tab")
        check("S-037 File > New Connection Tab is ⌘T", newTab?.keyEquivalent == "t" && newTab?.keyEquivalentModifierMask == [.command])
        let openTab = menuItem("Open Table in New Tab")
        check("S-037 Table > Open Table in New Tab is ⌃⌘T",
              openTab?.keyEquivalent == "t" && openTab?.keyEquivalentModifierMask == [.command, .control])
        let linkTab = menuItem("Open Referenced Row in New Tab")
        check("S-037 Table > Open Referenced Row in New Tab is ⌥⌘↓",
              linkTab?.keyEquivalent == String(UnicodeScalar(NSDownArrowFunctionKey)!) && linkTab?.keyEquivalentModifierMask.isSuperset(of: [.command, .option]) == true,
              "\(linkTab?.keyEquivalentModifierMask.rawValue ?? 0)")
        check("S-037 a table opens on Content; the order starts with Structure",
              Session().view == .content && DetailView.allCases.prefix(2) == [.structure, .content])

        session.database = "quarry_demo"
        await session.currentLoad?.value
        session.view = .content
        session.selectedObjectID = "table:order_items"
        await session.currentLoad?.value
        let parent = session.window

        // ⌘-click in the sidebar, or Open Table in New Tab.
        session.openObjectInNewTab("table:customers")
        guard let tab = await openedTab(after: nil) else {
            check("S-037 a new tab opens", false)
            return
        }
        firstTabWindow = Tabs.lastOpenedWindow
        await tab.waitForConnect()
        check("S-037 the new tab shows customers on Content",
              tab.phase == .connected && tab.selectedObjectID == "table:customers" && tab.view == .content && !tab.content.grid.rows.isEmpty,
              "\(tab.phase) \(tab.selectedObjectID ?? "nil") \(tab.view) \(tab.content.grid.rows.count) rows \(tab.connectProblem?.message ?? "")")
        check("S-037 the new tab has its own connection", tab.client != nil && tab.client !== session.client)
        check("S-037 the new tab joins the window's tab bar",
              parent == nil || (parent?.tabbedWindows?.contains { $0 === Tabs.lastOpenedWindow } ?? false),
              parent == nil ? "no key window" : "\(parent?.tabbedWindows?.count ?? 0) tabs")
        check("S-037 the first tab keeps its table", session.selectedObjectID == "table:order_items" && session.view == .content)

        // ⌘-click on a foreign-key arrow.
        if let orderID = session.content.grid.columns.firstIndex(where: { $0.title == "order_id" }) {
            let value = session.content.grid.rows.first?[orderID].plainText ?? ""
            session.followLinkInNewTab(row: 0, column: orderID)
            if let linked = await openedTab(after: tab) {
                let linkedWindow = Tabs.lastOpenedWindow
                await linked.waitForConnect()
                check("S-037 the referenced row opens in a new tab",
                      linked.selectedObjectID == "table:orders" && linked.content.filter.appliedClause == "`id` = '\(value)'"
                        && linked.content.grid.rows.count == 1,
                      "\(linked.selectedObjectID ?? "nil") \(linked.content.filter.appliedClause ?? "no filter")")
                check("S-037 and the first tab stays on order_items", session.selectedObjectID == "table:order_items" && !session.history.canGoBack)
                check("S-037 each tab has its own window", linkedWindow != nil && linkedWindow !== firstTabWindow)
                closeTab(linked)
            } else {
                check("S-037 the referenced row opens in a new tab", false,
                      "link \(session.linkPlace(row: 0, column: orderID) != nil) rows \(session.content.grid.rows.count) object \(session.selectedObjectID ?? "nil")")
            }
        }
        let tabWindow = firstTabWindow
        tab.disconnect()
        tabWindow?.close()

        // A real ⌘-click on "products" in the sidebar: a new tab, and this tab keeps order_items.
        await until { tabWindow?.isVisible != true }
        parent?.makeKeyAndOrderFront(nil)
        if let parent, let sidebar = sidebarTable(in: parent),
           let outline = sidebar as? NSOutlineView,
           let row = (0..<sidebar.numberOfRows).first(where: {
               ObjectSidebar.objectID(atRow: $0, in: outline, sections: [session.visibleObjects.filter { $0.kind == .table }]) == "table:products"
           }) {
            let rect = sidebar.rect(ofRow: row)
            let point = sidebar.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = { (type: NSEvent.EventType) in
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: parent.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            let before = Tabs.lastOpened
            if let down = event(.leftMouseDown), let up = event(.leftMouseUp) {
                // Through NSApp, as a real click goes, so the sidebar's event monitor sees it.
                NSApp.postEvent(up, atStart: false)
                NSApp.sendEvent(down)
            }
            let clicked = await openedTab(after: before)
            await clicked?.waitForConnect()
            check("S-037 ⌘-clicking a sidebar table opens it in a new tab",
                  clicked?.selectedObjectID == "table:products" && clicked?.view == .content,
                  clicked?.selectedObjectID ?? "no tab")
            await until { session.selectedObjectID == "table:order_items" }
            check("S-037 and the sidebar keeps this tab's table", session.selectedObjectID == "table:order_items",
                  session.selectedObjectID ?? "nil")
            check("S-037 the sidebar still shows this tab's table selected", sidebar.selectedRow != row,
                  "\(sidebar.selectedRowIndexes.map { $0 })")
            if let clicked { closeTab(clicked) }
        } else {
            check("S-037 ⌘-clicking a sidebar table opens it in a new tab", false, "no sidebar row for products")
        }
        await until { tabWindow?.isVisible != true }
        check("S-037 closing the tabs leaves one window",
              NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && !$0.isSheet }.count == 1,
              "\(NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count) windows")
        parent?.makeKeyAndOrderFront(nil)
        // With the app in the background no window becomes key, so hand the menus back here.
        MenuState.shared.activate(session)
    }

    /// The tab Tabs opened after `previous`, once its window has claimed it.
    static func openedTab(after previous: Session?) async -> Session? {
        for _ in 0..<100 {
            if let tab = Tabs.lastOpened, tab !== previous { return tab }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// The sidebar's list: the window's first table view that is not a grid.
    static func sidebarTable(in window: NSWindow) -> NSTableView? {
        ViewTree.first(NSTableView.self, in: window.contentView) { !($0 is GridTableView) }
    }

    /// The first tab's window, kept when it was claimed.
    static weak var firstTabWindow: NSWindow?

    static func closeTab(_ tab: Session) {
        tab.disconnect()
        Tabs.lastOpenedWindow?.close()
    }

    // MARK: S-059

    static func databaseTools(session: Session) async {
        // The window's default size: SwiftUI's inspector looped on its column
        // sizes here and crashed, with Query beside it (docs/FIXLOG.md).
        let frame = session.window?.frame
        session.window?.setFrame(NSRect(origin: frame?.origin ?? .zero, size: NSSize(width: 1180, height: 760)), display: true)
        session.database = "quarry_legacy"
        await session.currentLoad?.value
        let info = session.databaseInfo
        session.showsDatabaseInfo = true
        await info.waitUntilIdle()
        check("S-059 ⌥⌘I shows the database's overview",
              info.overview?.countsLine == "3 tables · 0 views · 0 routines" && MenuState.shared.snapshot.showsDatabaseInfo,
              info.overview?.countsLine ?? info.overviewError?.message ?? "no overview")
        check("S-059 Repair waits for Check Tables", !info.canRun(.repair))

        await session.runTool(.check)?.value
        check("S-059 Check Tables checks every table", info.checks.count == 3 && info.checks.allSatisfy { $0.severity == .ok },
              info.checks.map { "\($0.table): \($0.message)" }.joined(separator: ", "))
        check("S-059 healthy tables leave nothing to repair", info.tablesToRepair.isEmpty && !info.confirmingRepair)

        await session.runTool(.collations)?.value
        check("S-059 Find Collations flags the utf8mb3 tables",
              info.collations?.tablesToConvert.map(\.table) == ["notes", "visits"])

        session.showsDatabaseInfo = false
        info.reset()
        await session.runTool(.health)?.value
        let ids = Set(info.findings.map(\.id))
        check("S-059 Health Check finds the fixture's problems, even from the menu with the panel closed",
              ids.isSuperset(of: ["primary-key", "engine", "utf8mb3", "auto-increment:counters.id"]), "\(ids)")

        let fix = info.findings.first { $0.id == "engine" }?.sql ?? ""
        session.query.reset()
        session.openInQuery(fix)
        check("S-059 Open in Query puts the fix in the editor, unrun",
              session.view == .query && session.query.text == fix && session.query.results.columns.isEmpty)

        session.database = "quarry_demo"
        await session.currentLoad?.value
        await info.waitUntilIdle()
        check("S-059 the panel follows the database", info.overview?.name == "quarry_demo" && info.shown == nil)
        session.showsDatabaseInfo = false
        if let frame { session.window?.setFrame(frame, display: true) }
    }

    // MARK: S-020

    static func goToDatabase(session: Session) async {
        session.database = "quarry_demo"
        await session.currentLoad?.value
        session.requestGoToDatabase()
        guard let finder = session.goToDatabase else { return check("S-020 ⇧⌘D opens Go to Database", false) }
        check("S-020 the sheet lists every database, the first selected",
              finder.matches.count == session.databases.count && finder.selection == session.databases.first)
        finder.search = "qleg"
        check("S-020 letters in order find the database", finder.matches.map(\.name) == ["quarry_legacy"]
                  && finder.selection == "quarry_legacy", "\(finder.matches.map(\.name))")
        finder.search = "qa"
        let quarry = finder.matches.map(\.name)
        finder.moveSelection(by: 1)
        check("S-020 ↓ moves the selection", quarry.count > 1 && finder.selection == quarry[1], "\(quarry)")
        finder.search = "\"qa\""
        check("S-020 a quoted search matches as typed", finder.matches.isEmpty && !finder.canOpen)
        finder.search = "qleg"
        session.openFoundDatabase()
        await session.currentLoad?.value
        check("S-020 Open switches to the database and closes the sheet",
              session.goToDatabase == nil && session.database == "quarry_legacy" && !session.objects.isEmpty)
        session.database = "quarry_demo"
        await session.currentLoad?.value
    }
}
