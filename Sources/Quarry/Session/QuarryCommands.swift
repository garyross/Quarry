import AppKit
import QuarryKit
import QuarryControllers
import SwiftUI

/// Quarry's menus: File, Edit, View, Connection, Database and Help here;
/// Table and Query in their own files. Every command and its shortcut is in
/// `CommandMap` (S-040), which the self-test checks against this menu bar.
struct QuarryCommands: Commands {
    @ObservedObject var state: MenuState
    let model: AppModel
    private var menu: MenuState.Snapshot { state.snapshot }
    @Environment(\.openWindow) private var openWindow

    private var session: Session? { MenuState.shared.active }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Quarry") { openWindow(id: AboutWindow.sceneID) }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Connection Window") { openWindow(id: WindowRoot.sceneID) }
                .keyboardShortcut("n")
            // S-037: a native tab in the key window, on the Connect page.
            Button("New Connection Tab") {
                Tabs.openWindow = openWindow
                Tabs.open()
            }
            .keyboardShortcut("t")
            // S-040: another tab on the same server, showing the same place.
            Button("Duplicate Connection Tab") {
                Tabs.openWindow = openWindow
                session?.duplicateTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(menu.phase != .connected)
        }
        CommandGroup(after: .newItem) {
            // S-068: an empty SQLite file, opened like any other.
            Button("New SQLite File…") { session?.requestNewSQLiteFile() }
                .keyboardShortcut("n", modifiers: [.command, .control])
                .disabled(session == nil)
            // S-055: a connection or session file, from Quarry or Sequel Pro; S-068: a SQLite file.
            Button("Open…") { session?.chooseConnectionFile() }
                .keyboardShortcut("o")
                .disabled(session == nil)
            Divider()
            Button("Save Connection") { session.map { save($0) } }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(menu.phase != .disconnected)
            Button("Save Connection File…") { session?.requestSaveConnectionFile(asSession: false) }
                .keyboardShortcut("s")
                .disabled(menu.phase != .connected)
            Button("Save Session…") { session?.requestSaveConnectionFile(asSession: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(menu.phase != .connected)
        }
        CommandGroup(before: .printItem) {
            Button("Export…") { session?.requestExport() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!menu.canExport)
            Button("Import…") { session?.chooseImportFile() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!menu.canImport)
            Button("Import from Clipboard…") { session?.importFromClipboard() }
                .keyboardShortcut("i", modifiers: [.command, .shift, .option])
                .disabled(!menu.canImport)
            Divider()
        }

        CommandMenu("Connection") {
            Button("Connect") { session?.connect(model: model) }
                .keyboardShortcut(.return)
                .disabled(menu.phase != .disconnected)
            Button("Test Connection") { if let session { Task { await session.testConnection() } } }
                .disabled(menu.phase != .disconnected)
            Divider()
            // S-049: organize saved connections, as the Connect page's sidebar menus do.
            if let session {
                ConnectionCommands(model: model, session: session, uid: menu.selectedSaved)
                Divider()
                ConnectionListCommands(model: model, session: session)
                    .disabled(menu.phase != .disconnected)
            }
            Divider()
            Button("Disconnect") { session?.disconnect() }
                .keyboardShortcut("w", modifiers: [.command, .control])
                .disabled(menu.phase != .connected)
        }

        CommandGroup(before: .toolbar) {
            ForEach(DetailView.allCases) { view in
                Button(view.title) { session?.view = view }
                    .keyboardShortcut(KeyEquivalent(view.shortcut))
                    .disabled(menu.phase != .connected)
            }
            Divider()
            // S-038: every database, table and view shown, Sequel Pro's ⌃⌥← ⌃⌥→.
            // The toolbar arrows also answer ⌘[ ⌘] outside Query, where those
            // keys are Shift Left and Shift Right (S-032).
            Button("Back") { session?.goBack() }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .option])
                .disabled(!menu.canGoBack)
            Button("Forward") { session?.goForward() }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .option])
                .disabled(!menu.canGoForward)
            Divider()
            Button("Previous Page") { session?.movePage(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(!menu.hasPreviousPage)
            Button("Next Page") { session?.movePage(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(!menu.hasNextPage)
            Divider()
            Button("Refresh") { session?.refresh() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(menu.phase != .connected)
            Button("Filter Sidebar") { NotificationCenter.default.post(name: .focusSidebarFilter, object: session) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(menu.phase != .connected || !menu.hasDatabase)
            Divider()
            // S-039: Sequel Pro's ⌘K Clear Console is ⌥⌘K here, as ⌘K is too easy to hit.
            Button("Show Console") { openWindow(id: ConsoleWindow.sceneID) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Clear Console") { Console.shared.clear() }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(!state.responder.consoleHasLines)
            Divider()
        }

        CommandMenu("Database") {
            Button("Go to Database…") { session?.requestGoToDatabase() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(menu.phase != .connected)
            Divider()
            Button("New Database…") { session?.requestNewDatabase() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(menu.phase != .connected)
                .serverOnly("New Database…", on: menu.isSQLite)
            Button("Duplicate Database…") { session?.requestDatabaseEditor(.duplicate) }
                .keyboardShortcut("n", modifiers: [.command, .shift, .option])
                .disabled(!menu.canDuplicateDatabase)
                .serverOnly("Duplicate Database…", on: menu.isSQLite)
            Button("Rename Database…") { session?.requestDatabaseEditor(.rename) }
                .keyboardShortcut("r", modifiers: [.command, .shift, .option])
                .disabled(!menu.canEditDatabase)
                .serverOnly("Rename Database…", on: menu.isSQLite)
            Button("Change Character Set…") { session?.requestDatabaseEditor(.alter) }
                .keyboardShortcut("c", modifiers: [.command, .shift, .option])
                .disabled(!menu.canEditDatabase)
                .serverOnly("Change Character Set…", on: menu.isSQLite)
            Button("Delete Database…") { session?.requestDeleteDatabase() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(!menu.canEditDatabase)
                .serverOnly("Delete Database…", on: menu.isSQLite)
            Divider()
            Button(menu.isFavoriteDatabase ? "Remove from Favorites" : "Add to Favorites") {
                session?.toggleFavoriteDatabase()
            }
            .keyboardShortcut("d")
            .disabled(menu.phase != .connected || !menu.hasDatabase)
            .serverOnly("Add to Favorites", on: menu.isSQLite)
            Divider()
            // S-056: the check mark follows the key window's connection.
            Picker("View Using Encoding", selection: Binding(get: { menu.viewEncoding },
                                                             set: { session?.setViewEncoding($0) })) {
                ForEach(ViewEncoding.allCases) { Text($0.title).tag($0) }
            }
            .disabled(menu.phase != .connected)
            .serverOnly("View Using Encoding", on: menu.isSQLite)
            Divider()
            Button(menu.showsDatabaseInfo ? "Hide Database Information" : "Show Database Information") {
                session?.showsDatabaseInfo.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(menu.phase != .connected || !menu.hasDatabase)
            Divider()
            Button("Show Server Variables…") { session?.requestServerVariables() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(menu.phase != .connected)
                .serverOnly("Show Server Variables…", on: menu.isSQLite)
            Button("Show Server Processes…") { session?.requestProcessList() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(menu.phase != .connected)
                .serverOnly("Show Server Processes…", on: menu.isSQLite)
            Button("User Accounts…") { session?.requestUserAccounts() }
                .keyboardShortcut("u")
                .disabled(menu.phase != .connected)
                .serverOnly("User Accounts…", on: menu.isSQLite)
            Divider()
            // Maintenance runs rarely and Repair changes data, so these have
            // no shortcuts, as in Sequel Pro's Table menu.
            // Each engine's own tools (S-072): a SQLite window has no Check
            // Tables or Find Collations, a server window no Vacuum.
            ForEach(DatabaseInfo.Tool.tools(for: menu.isSQLite ? .sqlite : .mysql)) { tool in
                Button(tool.title) { session?.runTool(tool) }
                    .disabled(menu.phase != .connected || !menu.hasDatabase || !menu.runnableTools.contains(tool))
            }
        }

        CommandGroup(after: .pasteboard) {
            // Sent to the focused grid; disabled by the grid when nothing is selected.
            Button("Copy with Column Names") { NSApp.sendAction(#selector(GridCopying.copyWithColumnNames(_:)), to: nil, from: nil) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!state.responder.canCopyRows)
            Button("Copy as SQL INSERT") { NSApp.sendAction(#selector(GridCopying.copyAsSQLInsert(_:)), to: nil, from: nil) }
                .keyboardShortcut("c", modifiers: [.command, .option, .control])
                .disabled(!state.responder.canCopyInsert)
            Divider()
            // S-011: while a cell is being edited; elsewhere it does nothing.
            Button("Set to NULL") { NSApp.sendAction(#selector(GridCopying.setCellToNull(_:)), to: nil, from: nil) }
                .keyboardShortcut("n", modifiers: [.control, .shift])
                .disabled(!state.responder.isEditingCell)
        }

        // S-065: every request agents made, and the agents connected now.
        CommandGroup(before: .windowList) {
            Button("MCP Activity") { openWindow(id: MCPActivityWindow.sceneID) }
                .keyboardShortcut("m", modifiers: [.command, .option, .shift])
            Divider()
        }

        // S-040: no help book; the shortcuts and the servers' manuals instead.
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: KeyboardShortcutsWindow.sceneID) }
                .keyboardShortcut("?")
            Divider()
            Link("MySQL Reference Manual", destination: URL(string: "https://dev.mysql.com/doc/refman/8.4/en/")!)
            Link("MariaDB Documentation", destination: URL(string: "https://mariadb.com/kb/en/documentation/")!)
        }
    }

    private func save(_ session: Session) {
        session.selectedSaved = model.save(session.form, over: session.selectedSaved)
    }
}

