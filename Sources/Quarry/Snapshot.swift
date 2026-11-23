import AppKit
import IOKit.pwr_mgt
import QuarryKit
import SwiftUI

/// Screenshot mode for agents.
///   APP_STORE=/tmp/test.store APP_SNAPSHOT=/tmp/shots ~/Applications/Quarry.app/Contents/MacOS/Quarry
/// writes <page>-light.png and <page>-dark.png for every SnapshotPage, and
/// settings-<tab>-light.png and settings-<tab>-dark.png for every Settings tab, then quits.
/// Each PNG gets a <page>-<mode>-layout.json with the grid probes (tools/check-layout.swift).
/// APP_SNAPSHOT_PAGES=connection,content limits the pages. Add "settings" to include Settings.
/// Pages after the Connect page connect to the private test server (tools/testdb.sh).
/// Add APP_ACCENT=<id> to see the pages in another accent.
enum Snapshot {
    /// Only the first window takes the pictures; the tabs it opens do not.
    private static var started = false

    static func runIfRequested(model: AppModel, session: Session, openSettings: OpenSettingsAction) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["APP_SNAPSHOT"], !dir.isEmpty, !started else { return }
        started = true
        // Snapshots never run against the real database.
        guard Store.isOverridden else {
            print("SNAPSHOT refused: set APP_STORE to a file in /tmp")
            NSApp.terminate(nil)
            return
        }
        let only = env["APP_SNAPSHOT_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        Task {
            // A sleeping display gives screencapture nothing. Declaring user
            // activity wakes it; the assertion keeps it on until the run quits.
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Snapshots" as CFString, kIOPMUserActiveLocal, &activity)
            var awake: IOPMAssertionID = 0
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Snapshots" as CFString, &awake)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1.5))
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                for page in SnapshotPage.allCases where only?.contains(page.rawValue) ?? true {
                    await page.prepare(session, model: model)
                    try? await Task.sleep(for: .seconds(0.8))
                    if page.showsSheet {
                        let main = NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }
                        capture(to: "\(dir)/\(page.rawValue)-\(mode).png", window: main?.attachedSheet)
                    } else if page == .contentContextMenu {
                        await captureContextMenu(to: "\(dir)/\(page.rawValue)-\(mode).png")
                    } else if page == .queryCompletion {
                        captureWithChildWindows(to: "\(dir)/\(page.rawValue)-\(mode).png")
                    } else if page == .queryHistoryMenu {
                        capturePopover(to: "\(dir)/\(page.rawValue)-\(mode).png")
                        session.query.showsHistory = false
                        try? await Task.sleep(for: .seconds(0.4))
                    } else if page == .queryFavoritesMenu {
                        capturePopover(to: "\(dir)/\(page.rawValue)-\(mode).png")
                        session.query.showsSavedQueries = false
                        try? await Task.sleep(for: .seconds(0.4))
                    } else if page == .queryFavoriteManager {
                        await captureSavedQueriesWindow(model, to: "\(dir)/\(page.rawValue)-\(mode).png")
                    } else if page == .keyboardShortcuts {
                        await captureWindow(KeyboardShortcutsWindow(), title: "Keyboard Shortcuts", size: NSSize(width: 600, height: 640),
                                            to: "\(dir)/\(page.rawValue)-\(mode).png")
                    } else if page == .console {
                        await captureWindow(ConsoleWindow(), title: "Console", size: NSSize(width: 860, height: 420),
                                            to: "\(dir)/\(page.rawValue)-\(mode).png")
                    } else if page == .mcpActivity {
                        await captureWindow(MCPActivityWindow().environment(model), title: "MCP Activity",
                                            size: NSSize(width: 1040, height: 400), to: "\(dir)/\(page.rawValue)-\(mode).png")
                    } else if page == .about {
                        await captureWindow(AboutWindow(), title: "About Quarry", size: NSSize(width: 600, height: 320),
                                            to: "\(dir)/\(page.rawValue)-\(mode).png")
                    } else if page == .processes {
                        await captureProcesses(session, to: "\(dir)/\(page.rawValue)-\(mode).png")
                    } else if page == .structureEditing {
                        await captureTypeMenu(to: "\(dir)/\(page.rawValue)-\(mode).png")
                    } else if page == .tableContextMenu || page == .connectionContextMenu {
                        await captureSidebarMenu(to: "\(dir)/\(page.rawValue)-\(mode).png")
                    } else if page == .browserTabs {
                        // The new tab is the one showing; close it after, so the pages after see one window.
                        capture(to: "\(dir)/\(page.rawValue)-\(mode).png", window: Tabs.lastOpenedWindow)
                        Tabs.lastOpened?.disconnect()
                        Tabs.lastOpenedWindow?.close()
                        NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }?.makeKeyAndOrderFront(nil)
                    } else {
                        capture(to: "\(dir)/\(page.rawValue)-\(mode).png")
                    }
                }
            }
            if only == nil || only?.contains("settings") == true {
                let main = NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }
                openSettings()
                try? await Task.sleep(for: .seconds(1))
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    for tab in SettingsTab.allCases {
                        model.settingsTab = tab
                        try? await Task.sleep(for: .seconds(0.8))
                        let settings = NSApp.windows.first { $0.isVisible && $0 !== main && !$0.isSheet }
                        capture(to: "\(dir)/settings-\(tab.rawValue)-\(mode).png", window: settings)
                    }
                    // S-064: the token sheet, editing and then showing a new token's value once.
                    model.settingsTab = .mcp
                    let draft = TokenDraft(token: nil)
                    draft.name = "Cursor"
                    draft.access = AgentAccess(permission: .readWrite, allConnections: false,
                                               connections: Set(model.savedConnections().prefix(1).map(\.uid)))
                    MCPHost.shared.tokenDraft = draft
                    try? await Task.sleep(for: .seconds(0.8))
                    let settings = NSApp.windows.first { $0.isVisible && $0 !== main && !$0.isSheet }
                    capture(to: "\(dir)/settings-mcp-token-\(mode).png", window: settings?.attachedSheet)
                    draft.createdValue = "qmcp_" + String(repeating: "x7Kp", count: 10) + "Q2"
                    try? await Task.sleep(for: .seconds(0.5))
                    capture(to: "\(dir)/settings-mcp-token-created-\(mode).png", window: settings?.attachedSheet)
                    MCPHost.shared.tokenDraft = nil
                    try? await Task.sleep(for: .seconds(0.5))
                    // S-066: Manual Setup…
                    MCPHost.shared.showingManualSetup = true
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(to: "\(dir)/settings-mcp-manual-\(mode).png", window: settings?.attachedSheet)
                    MCPHost.shared.showingManualSetup = false
                    try? await Task.sleep(for: .seconds(0.5))
                }
            }
            print("SNAPSHOT done \(dir)")
            // A SwiftUI sheet closes through its state; endSheet alone leaves it up.
            session.closeSheets()
            try? await Task.sleep(for: .seconds(0.5))
            // An open sheet refuses terminate, and the run would wait forever.
            for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
            NSApp.terminate(nil)
        }
    }

    /// Opens the grid's row menu over the selected rows and captures the window
    /// with its menu, by window number (S-010).
    @MainActor
    private static func captureContextMenu(to path: String) async {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }),
              let table = ViewTree.first(GridTableView.self, in: window.contentView) else {
            print("SNAPSHOT no grid for the context menu")
            return
        }
        let row = table.selectedRowIndexes.first ?? 0
        popUpMenu(of: table, at: NSPoint(x: table.rect(ofColumn: 1).minX + 40, y: table.rect(ofRow: row).midY),
                  in: window, to: path)
    }

    /// Clicks the Edit Field sheet's type menu (found by its grid probe) and
    /// captures the sheet's window group while the menu tracks (S-023).
    @MainActor
    private static func captureTypeMenu(to path: String) async {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }),
              let sheet = window.attachedSheet, let content = sheet.contentView,
              let probe = GridProbes.shared.probes["probe:type-menu"] else {
            print("SNAPSHOT no type menu")
            return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(300))
        nonisolated(unsafe) var opened: NSMenu?
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                                              queue: nil) { note in opened = note.object as? NSMenu }
        // The sheet's number captures its window group: the window, the sheet and the open menu.
        let shown = sheet
        let timer = Timer(timeInterval: 1.2, repeats: false) { _ in
            MainActor.assumeIsolated { captureWindowWithMenu(shown, to: path, menuOpened: opened != nil) }
            opened?.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)
        try? FileManager.default.removeItem(atPath: path)
        // The probe is in top-left points of the sheet's content; events want bottom-left.
        let location = NSPoint(x: probe.x + probe.width - 40, y: content.bounds.height - (probe.y + probe.height / 2))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: sheet.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1) else { continue }
            sheet.sendEvent(event)
        }
        try? await Task.sleep(for: .seconds(2))
        NotificationCenter.default.removeObserver(observer)
    }

    /// Right-clicks the sidebar's selected table and captures its menu (S-022).
    @MainActor
    private static func captureSidebarMenu(to path: String) async {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }),
              let outline = ViewTree.first(NSOutlineView.self, in: window.contentView?.superview) else {
            print("SNAPSHOT no sidebar for the context menu")
            return
        }
        let row = outline.selectedRowIndexes.first ?? 1
        let rect = outline.rect(ofRow: row)
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(300))
        // SwiftUI fills its list menu only on a real right-click, so the window gets one;
        // the menu is caught as it starts tracking, to close it after the capture.
        let main = window
        nonisolated(unsafe) var opened: NSMenu?
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                                              queue: nil) { note in opened = note.object as? NSMenu }
        let timer = Timer(timeInterval: 1.5, repeats: false) { _ in
            MainActor.assumeIsolated { captureWindowWithMenu(main, to: path, menuOpened: opened != nil) }
            opened?.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)
        try? FileManager.default.removeItem(atPath: path)
        let location = outline.convert(NSPoint(x: rect.minX + 60, y: rect.midY), to: nil)
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1) else { continue }
            window.sendEvent(event)
        }
        // If the menu tracked inside sendEvent, the capture is done; else wait for the timer.
        try? await Task.sleep(for: .seconds(2))
        NotificationCenter.default.removeObserver(observer)
    }

    /// The window with its open menu, captured by window number, so another
    /// app's window in front never gets into the picture. On macOS 26 a
    /// window's capture includes its context menu.
    /// Says when no file was written (the window was not on screen), rather than claiming a snapshot.
    @MainActor
    private static func captureWindowWithMenu(_ window: NSWindow, to path: String, menuOpened: Bool = true) {
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
        try? shot.run()
        shot.waitUntilExit()
        if FileManager.default.fileExists(atPath: path) {
            print("SNAPSHOT \(path)\(menuOpened ? "" : " (no menu opened)")")
        } else {
            print("SNAPSHOT FAILED \(path): the window could not be captured")
        }
    }

    /// The main window with its child window (the completion list, S-031).
    /// A capture by the child's window number takes the whole window group,
    /// and still no other app's window can get into the picture.
    @MainActor
    private static func captureWithChildWindows(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else { return }
        let child = window.childWindows?.first { $0.isVisible }
        if child == nil { print("SNAPSHOT no child window") }
        capture(to: path, window: window, number: child?.windowNumber)
        // Close it, so later pages and the Settings captures do not find it.
        for child in window.childWindows ?? [] {
            window.removeChildWindow(child)
            child.orderOut(nil)
        }
    }

    /// Manage Saved Queries… (S-034): the window on its own, built here
    /// since snapshot mode has no openWindow.
    @MainActor
    private static func captureSavedQueriesWindow(_ model: AppModel, to path: String) async {
        let host = NSHostingController(rootView: SavedQueriesWindow().environment(model).themed())
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.title = "Saved Queries"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 760, height: 480))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: path, window: window)
        window.close()
        NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }?.makeKeyAndOrderFront(nil)
    }

    /// Server Processes (S-053) with a SLEEP running on a third connection, so a Query row shows.
    @MainActor
    private static func captureProcesses(_ session: Session, to path: String) async {
        guard let client = session.client, let sleeper = try? await client.secondConnection() else { return }
        let sleeping = Task { _ = try? await sleeper.run("SELECT SLEEP(20) AS quarry_snapshot") }
        let list = ProcessList(server: session.connectedDetails?.displayName ?? "", source: client)
        ProcessList.open[list.id] = list
        list.autoRefresh = false
        try? await Task.sleep(for: .seconds(1.5))
        await list.start()
        list.selection = Set(list.processes.filter { $0.info?.contains("quarry_snapshot") == true }.map(\.id))
        await captureWindow(ProcessListView(list: list), title: "Server Processes", size: NSSize(width: 960, height: 400), to: path)
        if let id = sleeper.connectionID { try? await client.kill(Int64(id), connection: false) }
        _ = await sleeping.value
        await sleeper.close()
        list.autoRefresh = true
        list.stop()
    }

    /// A window scene on its own (S-039), built here since snapshot mode has no openWindow.
    @MainActor
    private static func captureWindow(_ view: some View, title: String, size: NSSize, to path: String) async {
        let host = NSHostingController(rootView: view.themed())
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: path, window: window)
        window.close()
        NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }?.makeKeyAndOrderFront(nil)
    }

    /// The popover's own window (S-033). A capture of the screen area would
    /// take in any other app's window in front.
    @MainActor
    private static func capturePopover(to path: String) {
        guard let popover = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) else {
            return print("SNAPSHOT no popover")
        }
        capture(to: path, window: popover)
    }

    /// popUp runs its own loop; the capture runs from a timer inside it.
    @MainActor
    private static func popUpMenu(of view: NSView, at point: NSPoint, in window: NSWindow, to path: String) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        // A right-click as the window would get it: popUpContextMenu needs an event to place the menu.
        let location = view.convert(point, to: nil)
        guard let click = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let menu = view.menu(for: click) ?? view.menu else {
            print("SNAPSHOT no menu")
            return
        }
        nonisolated(unsafe) let shown = menu
        let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
            MainActor.assumeIsolated { captureWindowWithMenu(window, to: path) }
            shown.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)
        try? FileManager.default.removeItem(atPath: path)
        NSMenu.popUpContextMenu(menu, with: click, for: view)
    }

    /// Captures the real window with screencapture, so glass, sidebars, and
    /// materials look exactly as on screen. That needs Screen Recording
    /// permission for the app that started this one (your terminal, or Claude).
    /// Without it, falls back to drawing the view hierarchy, which leaves
    /// sidebars and glass blank.
    private static func capture(to path: String, window: NSWindow? = nil, number: Int? = nil) {
        // Another app can hide this one while snapshots run (computer use hides
        // apps it does not control). Hidden windows cannot be captured.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard let window = window ?? NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            print("SNAPSHOT no window")
            return
        }
        // Active, like a window someone is using: real accent colors and focus rings.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let size = window.contentView?.bounds.size ?? .zero
        GridProbes.shared.write(to: path.replacingOccurrences(of: ".png", with: "-layout.json"), window: size)
        try? FileManager.default.removeItem(atPath: path)
        // The first capture of a run sometimes misses the window. Try three times.
        for _ in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(number ?? window.windowNumber), path]
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                print("SNAPSHOT \(path)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback: no Screen Recording permission, sidebars and glass are blank)")
        }
    }
}

/// The pages snapshot mode visits, in order. Each one sets up the window itself.
enum SnapshotPage: String, CaseIterable {
    case connection, connectionError = "connection-error", connectionSocket = "connection-socket"
    case connectionSSL = "connection-ssl"
    case connectionContextMenu = "connection-context-menu"
    case connectionSSH = "connection-ssh", sshTrust = "ssh-trust", sshPassword = "ssh-password"
    case browser, browserFiltered = "browser-filtered"
    case structure, structureEditing = "structure-editing", fieldSheet = "field-sheet", newIndex = "new-index"
    case content, contentLarge = "content-large", contentEditError = "content-edit-error"
    case contentContextMenu = "content-context-menu", contentNewRow = "content-new-row"
    case contentFiltered = "content-filtered", contentNoMatch = "content-no-match", contentRules = "content-rules"
    case contentWhere = "content-where", contentWhereError = "content-where-error"
    case fieldEditor = "field-editor", fieldEditorHex = "field-editor-hex", fieldEditorImage = "field-editor-image"
    case bitEditor = "bit-editor"
    case contentLinks = "content-links", contentFollowed = "content-followed"
    case browserTabs = "browser-tabs"
    case foreignKeys = "foreign-keys", newForeignKey = "new-foreign-key", triggers, newTrigger = "new-trigger", info
    case query, queryError = "query-error", queryRunning = "query-running", queryCompletion = "query-completion"
    case queryHistoryMenu = "query-history-menu"
    case queryFavoritesMenu = "query-favorites-menu", saveQuery = "save-query", queryFavoriteManager = "query-favorite-manager"
    case console
    case keyboardShortcuts = "keyboard-shortcuts"
    case databaseInfo = "database-info", databaseHealth = "database-health", databaseCollations = "database-collations"
    case newDatabase = "new-database", goToDatabase = "go-to-database", newTable = "new-table"
    case duplicateDatabase = "duplicate-database", changeCharacterSet = "change-character-set"
    case tableContextMenu = "table-context-menu", tableRename = "table-rename", duplicateTable = "duplicate-table"
    case deleteTables = "delete-tables", createSyntax = "create-syntax", export, exportCSV = "export-csv"
    case importSQL = "import", importError = "import-error", importCSV = "import-csv", csvMapping = "csv-mapping"
    case importClipboard = "import-clipboard"
    case newView = "new-view", editFunction = "edit-function"
    case connectionLost = "connection-lost", connectionLostError = "connection-lost-error"
    case usersGeneral = "users-general", usersGlobal = "users-global", usersSchema = "users-schema"
    case usersResources = "users-resources", serverVariables = "server-variables", processes
    case saveConnectionFile = "save-connection-file", about
    case agentApproval = "agent-approval", mcpActivity = "mcp-activity"
    case connectSQLite = "connect-sqlite", sqliteContent = "sqlite-content", sqliteQuery = "sqlite-query"
    case sqliteNotesInfo = "sqlite-notes-info", sqliteExport = "sqlite-export", sqliteDatabaseInfo = "sqlite-database-info"
    case sqliteStructure = "sqlite-structure", sqliteInfo = "sqlite-info", sqliteFieldSheet = "sqlite-field-sheet"
    case sqliteNewForeignKey = "sqlite-new-foreign-key"

    /// Pages captured as their sheet, not the window.
    var showsSheet: Bool { [.fieldEditor, .fieldEditorHex, .fieldEditorImage, .bitEditor, .newDatabase, .goToDatabase,
                                         .newTable, .duplicateDatabase, .changeCharacterSet, .duplicateTable, .deleteTables, .fieldSheet,
                                         .newIndex, .newForeignKey, .newTrigger, .createSyntax, .newView, .editFunction,
                                         .connectionLost, .connectionLostError, .saveQuery, .export, .exportCSV,
                                         .importSQL, .importError, .importCSV, .csvMapping, .importClipboard,
                                         .sshTrust, .sshPassword, .usersGeneral, .usersGlobal, .usersSchema,
                                         .usersResources, .serverVariables, .saveConnectionFile, .agentApproval, .sqliteExport,
                                         .sqliteFieldSheet, .sqliteNewForeignKey].contains(self) }

    func prepare(_ session: Session, model: AppModel) async {
        session.closeSheets()
        session.sidebarSelection = session.selectedObjectID.map { [$0] } ?? []
        try? await Task.sleep(for: .seconds(0.3))
        let local = model.savedConnections().first { $0.name == SeedData.local.name }
        switch self {
        case .connection, .connectionContextMenu:
            // S-049: the seed's Local is green and the default; Staging is in the group Work.
            session.disconnect()
            session.show(saved: local)
            return
        case .connectionSocket:
            session.disconnect()
            session.show(saved: model.savedConnections().first { $0.name == SeedData.localSocket.name })
            return
        case .connectionSSL:
            // S-058: Local with SSL on, a client certificate and a CA certificate.
            session.disconnect()
            session.show(saved: local)
            session.form.useSSL = true
            session.form.sslKey = "~/certs/client-key.pem"
            session.form.sslCertificate = "~/certs/client-cert.pem"
            session.form.sslCA = "~/certs/ca.pem"
            return
        case .connectionSSH, .sshTrust, .sshPassword:
            // S-047: the Staging seed connection goes through an SSH host; its two questions as sheets.
            session.disconnect()
            session.show(saved: model.savedConnections().first { $0.name == SeedData.staging.name })
            let login = session.form.ssh ?? SSHTunnel.Login(host: "staging.example.internal", user: "deploy")
            if self == .sshTrust {
                let key = SSHTunnel.HostKey(host: "staging.example.internal", type: "ED25519",
                                            fingerprint: "SHA256:0kH5mXq1v8hQ3cR2bN9zT4yW7uE6pL1sA5dF8gJ2kV0")
                session.ask(SSHQuestion(prompt: .unknownHost(key), login: login), retry: .connect)
            } else if self == .sshPassword {
                session.ask(SSHQuestion(prompt: .passphrase(NSHomeDirectory() + "/.ssh/id_ed25519"), login: login), retry: .connect)
            }
            return
        case .connectSQLite, .sqliteContent, .sqliteQuery, .sqliteNotesInfo, .sqliteExport, .sqliteDatabaseInfo,
             .sqliteStructure, .sqliteInfo, .sqliteFieldSheet, .sqliteNewForeignKey:
            await prepareSQLite(session, model: model)
            return
        case .connectionError:
            session.disconnect()
            session.show(saved: local)
            session.form.password = "not-the-password"
            session.connect(model: model)
            await session.waitForConnect()
            return
        default:
            break
        }
        // The SQLite pages leave a file open; the rest show the test server.
        if session.isSQLite { session.disconnect() }
        if session.phase != .connected {
            session.show(saved: local)
            session.connect(model: model)
            await session.waitForConnect()
        }
        let wanted = [.databaseHealth, .databaseCollations].contains(self) ? "quarry_legacy" : SeedData.local.database
        if session.database != wanted {
            session.database = wanted
            await session.currentLoad?.value
        }
        session.showsDatabaseInfo = false
        session.content.discardDraft()
        if session.content.isFiltered || !session.content.filter.draft.isEmpty {
            session.content.filter.draft.setMatch(session.content.filter.draft.root.id, .all)
            session.clearFilter()
            await session.currentLoad?.value
        }
        session.objectFilter = self == .browserFiltered ? "ord" : ""
        var ready: Bool?
        if ready == nil { ready = await prepareConnect(session, model: model, local: local) }
        if ready == nil { ready = await prepareDatabase(session, model: model, local: local) }
        if ready == nil { ready = await prepareStructure(session, model: model, local: local) }
        if ready == nil { ready = await prepareContent(session, model: model, local: local) }
        if ready == nil { ready = await prepareQuery(session, model: model, local: local) }
        if ready == nil { ready = await prepareTransfer(session, model: model, local: local) }
        if ready == nil { ready = await prepareServer(session, model: model, local: local) }
        if ready == true { return }
        await session.currentLoad?.value
    }

    @MainActor
    func selectGridRows(_ rows: IndexSet) {
        let window = NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }
        ViewTree.first(GridTableView.self, in: window?.contentView)?.selectRowIndexes(rows, byExtendingSelection: false)
    }

    func show(_ view: DetailView, _ object: String, in session: Session) {
        session.view = view
        session.selectedObjectID = object
    }
}

extension SnapshotPage {
    /// MCP Activity's sample requests, newest first.
    static func sampleActivity() -> [ActivityRecord] {
        let rows: [(Double, String, String, String, String, String, ActivityRecord.Status, String, Double)] = [
            (40, "claude-code 2.1.0", "Automatic", "quarry_demo", "read_query",
             "SELECT c.name, SUM(o.total) AS spent FROM customers c JOIN orders o ON o.customer_id = c.id GROUP BY c.id", .ok, "", 0.042),
            (95, "claude-code 2.1.0", "Automatic", "quarry_demo", "write_query",
             "UPDATE customers SET status = 'inactive' WHERE last_order_at < '2025-01-01'", .denied, "The person denied this change.", 31.2),
            (130, "claude-code 2.1.0", "Automatic", "quarry_demo", "describe_table", "table: customers", .ok, "", 0.018),
            (300, "cursor 1.7", "Reporting", "quarry_demo", "read_query", "SELECT * FROM order_totals ORDER BY total DESC", .ok, "", 0.006),
            (420, "cursor 1.7", "Reporting", "quarry_demo", "read_query", "SELECT COUNT(*) FROM evnts",
             .error, "Table 'quarry_demo.evnts' doesn't exist", 0.003),
            (900, "cursor 1.7", "Reporting", "", "list_tables", "", .ok, "", 0.011),
            (3_600, "codex 0.40", "CI", "quarry_legacy", "table_sizes", "", .ok, "", 0.087),
        ]
        return rows.map { row in
            ActivityRecord(date: .now.addingTimeInterval(-row.0), client: row.1, token: row.2, connection: "Local", database: row.3,
                           tool: row.4, statement: row.5, status: row.6, message: row.7, duration: row.8)
        }
    }

    /// The saved queries the S-034 pages show, replacing any from an earlier run.
    @MainActor
    func seedSavedQueries(_ model: AppModel) {
        model.importSavedQueries([
            .init(name: "Big spenders", query: "SELECT c.name, SUM(o.total) AS spent\nFROM customers c\nJOIN orders o ON o.customer_id = c.id\nGROUP BY c.id\nHAVING spent > 1000\nORDER BY spent DESC;"),
            .init(name: "Orders shipped this week", query: "SELECT * FROM orders WHERE status = 'shipped' AND placed_at >= CURDATE() - INTERVAL 7 DAY;"),
            .init(name: "Table sizes", query: "SELECT table_name, ROUND((data_length + index_length) / 1024 / 1024, 1) AS mb\nFROM information_schema.tables\nWHERE table_schema = DATABASE()\nORDER BY mb DESC;"),
            .init(name: "Running queries", query: "SHOW FULL PROCESSLIST;"),
        ], replacing: true)
    }
}
