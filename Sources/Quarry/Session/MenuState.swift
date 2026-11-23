import AppKit
import Combine
import SwiftUI
import QuarryKit
import QuarryControllers

/// The key window's session, mirrored for the menu bar. SwiftUI `Commands`
/// do not observe `@Observable` models, so the commands observe this object
/// and rebuild the menus when the snapshot changes (swift-swiftui skill,
/// "Menu commands"). Not the App: a change there re-runs the whole scene and
/// re-measures the toolbar on every table switch (docs/FIXLOG.md).
@MainActor
final class MenuState: ObservableObject {
    static let shared = MenuState()

    struct Snapshot: Equatable {
        var phase: Session.Phase = .disconnected
        /// The window has a SQLite file open: server commands gray out (S-068).
        var isSQLite = false
        /// A SQLite file opened with Open Read Only: New Table and New View gray out (S-068).
        var isReadOnly = false
        /// The saved connection selected on the Connect page (S-049).
        var selectedSaved: UUID?
        var view: DetailView = .content
        var hasDatabase = false
        var hasObject = false
        var canRunQuery = false
        /// A query runs and no cancel is on its way (S-036).
        var canCancelQuery = false
        /// The Query view's editor is showing: Show Completions and the editing commands (S-031, S-032).
        var canShowCompletions = false
        /// This server has query history (S-033).
        var hasQueryHistory = false
        /// The query editor isn't empty: Save Query… (S-034).
        var hasQueryText = false
        var showsDatabaseInfo = false
        /// Database > View Using Encoding's check mark (S-056).
        var viewEncoding: ViewEncoding = .utf8mb4
        var isFavoriteDatabase = false
        /// Rename, Change Character Set and Delete: not on a system database (S-019).
        var canEditDatabase = false
        var canDuplicateDatabase = false
        var runnableTools: Set<DatabaseInfo.Tool> = []
        var hasPreviousPage = false
        var hasNextPage = false
        var canAddRow = false
        var canDuplicateRow = false
        /// Only while the grid has focus, so ⌘⌫ still edits text elsewhere.
        var canDeleteRows = false
        var selectedRowCount = 0
        /// Structure's field commands (S-023).
        var canEditField = false
        var canMoveFieldUp = false
        var canMoveFieldDown = false
        /// Structure's index commands (S-024); ⌘⌫ deletes indexes while their grid has focus.
        var canAddIndex = false
        var indexGridHasFocus = false
        var canDeleteIndexes = false
        var deleteIndexTitle = "Delete Index…"
        /// Foreign Keys' commands (S-025); ⌘⌫ deletes keys while their grid has focus.
        var canAddForeignKey = false
        var canDeleteForeignKeys = false
        var deleteForeignKeyTitle = "Delete Foreign Key…"
        /// Triggers' commands (S-026); ⌘⌫ deletes triggers while their grid has focus.
        var canAddTrigger = false
        var canEditTrigger = false
        var canDeleteTriggers = false
        var deleteTriggerTitle = "Delete Trigger…"
        /// Info (S-027).
        var canResetAutoIncrement = false
        var canFilter = false
        var canSaveFilter = false
        /// The shown table's saved filters, for Table > Saved Filters.
        var savedFilters: [SavedFilterItem] = []
        var isFiltered = false
        var canOpenReferencedRow = false
        var openInNewTabTitle = "Open Table in New Tab"
        var canGoBack = false
        var canGoForward = false
        /// S-021, S-030: New Table…, New View…, New Procedure…, New Function… (`ObjectActions.canCreate`).
        var creatableKinds: Set<ObjectKind> = []
        /// S-022: titles and availability for the sidebar's selection.
        var renameTitle = "Rename Table…"
        var canRenameTable = false
        var canDuplicateTable = false
        /// S-030: Edit View…, Edit Procedure…, Edit Function… for the one selected.
        var editDefinitionTitle = "Edit View…"
        var canEditDefinition = false
        var emptyTitle = "Empty Table…"
        var canEmptyTables = false
        var deleteTitle = "Delete Table…"
        var canDeleteTables = false
        /// S-028: Show and Copy Create Statement, for any selected object.
        var canShowCreateStatement = false
        /// File > Export… (S-041).
        var canExport = false
        /// File > Import… (S-044).
        var canImport = false
        /// S-029: Table > Maintenance, the operations that can run now and their titles.
        var tableOperationTitles: [TableOperation: String] = [:]
    }

    @Published private(set) var snapshot = Snapshot()
    /// The session of the key window. Menu actions resolve it when they fire.
    private(set) weak var active: Session?

    func activate(_ session: Session) {
        active = session
        update(session)
    }

    func update(_ session: Session) {
        guard session === active else { return }
        let new = session.menuSnapshot
        if new != snapshot { snapshot = new }
    }

    /// What the first responder can do, for commands sent down the responder
    /// chain (Edit's grid commands) and the Console (S-040). SwiftUI menu items
    /// can't ask the responder chain, so this is read after every event.
    struct Responder: Equatable {
        var canCopyRows = false
        var canCopyInsert = false
        var isEditingCell = false
        var canOpenFieldEditor = false
        var consoleHasLines = false
    }

    @Published private(set) var responder = Responder()
    private var updates: NSObjectProtocol?

    private init() {
        updates = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil,
                                                         queue: .main) { _ in
            MainActor.assumeIsolated { MenuState.shared.refreshResponder() }
        }
    }

    func refreshResponder() {
        let grid = NSApp.target(forAction: #selector(GridCopying.copyWithColumnNames(_:)), to: nil, from: nil) as? GridTableView
        let new = Responder(
            canCopyRows: grid?.canPerform(#selector(GridCopying.copyWithColumnNames(_:))) ?? false,
            canCopyInsert: grid?.canPerform(#selector(GridCopying.copyAsSQLInsert(_:))) ?? false,
            isEditingCell: grid?.canPerform(#selector(GridCopying.setCellToNull(_:))) ?? false,
            canOpenFieldEditor: grid?.canPerform(#selector(GridCopying.openInFieldEditor(_:))) ?? false,
            consoleHasLines: !Console.shared.messages.isEmpty)
        if new != responder { responder = new }
    }
}

extension View {
    /// S-068: a command that needs a server grays out on a SQLite window, with
    /// `CommandMap`'s tooltip ("SQLite files have no server, so there are no user accounts.").
    func serverOnly(_ title: String, on isSQLite: Bool) -> some View {
        let help = CommandMap.all.first { $0.titles.contains(title) }?.sqliteHelp ?? ""
        return disabled(isSQLite).help(isSQLite ? help : "")
    }
}

/// A saved filter as the menu bar lists it.
struct SavedFilterItem: Equatable {
    let id: UUID
    let name: String
}

extension Notification.Name {
    /// View > Filter Sidebar (⌥⌘F). The object is the session whose window should react.
    static let focusSidebarFilter = Notification.Name("app.quarry.focusSidebarFilter")
}
