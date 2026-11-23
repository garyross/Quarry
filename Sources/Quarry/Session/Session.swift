import AppKit
import Foundation
import Observation
import QuarryKit
import QuarryControllers
import SwiftUI

/// The six detail views, ⌘1–⌘6.
enum DetailView: String, CaseIterable, Identifiable {
    case structure, content, foreignKeys, triggers, info, query

    var id: String { rawValue }

    var title: String {
        switch self {
        case .structure: "Structure"
        case .content: "Content"
        case .foreignKeys: "Foreign Keys"
        case .triggers: "Triggers"
        case .info: "Info"
        case .query: "Query"
        }
    }

    var symbol: String {
        switch self {
        case .structure: "list.bullet.rectangle"
        case .content: "tablecells"
        case .foreignKeys: "link"
        case .triggers: "bolt"
        case .info: "info.circle"
        case .query: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// "1"..."6"
    var shortcut: Character { Character(String((DetailView.allCases.firstIndex(of: self) ?? 0) + 1)) }

    var help: String {
        let what = switch self {
        case .structure: "Show the table's fields and indexes"
        case .content: "Show the table's rows"
        case .foreignKeys: "Show the table's foreign keys"
        case .triggers: "Show the table's triggers"
        case .info: "Show information about the object and its create statement"
        case .query: "Write and run SQL"
        }
        return "\(what) (⌘\(shortcut))"
    }

    /// Whether this view has something to show for an object of this kind.
    func applies(to kind: ObjectKind?) -> Bool {
        switch self {
        case .query: true
        case .info: kind != nil
        case .structure, .content: kind?.hasRows == true
        case .foreignKeys, .triggers: kind == .table
        }
    }
}

/// One window's connection: the Connect form before connecting, then the
/// database, the sidebar objects, and each detail view's state.
@Observable
final class Session {
    enum Phase: Equatable { case disconnected, connecting, connected }

    enum TestResult: Equatable {
        case success(String)
        case failure(DatabaseError)
    }

    // MARK: Connect page

    var form = ConnectionDetails()
    /// The saved connection the form shows, if any.
    var selectedSaved: UUID?
    /// The favorite database the form shows, if any (S-060).
    var selectedFavorite: UUID?
    /// S-049: the Connect page's inline rename, of a connection or a group, and the connection Delete asks about.
    var renamingConnection: UUID?
    var renamingGroup: UUID?
    var pendingDeleteSaved: UUID?
    var phase: Phase = .disconnected
    var connectProblem: DatabaseError?
    var testResult: TestResult?
    var isTesting = false
    /// A question SSH asked while connecting (S-047): Trust Host, or a password or passphrase.
    var sshQuestion: SSHQuestion?
    /// An agent's change waiting for Allow or Deny (S-064).
    var agentApproval: AgentApproval?
    /// What answering `sshQuestion` tries again.
    @ObservationIgnored var sshRetry: SSHRetry = .connect
    @ObservationIgnored var connectTask: Task<Void, Never>?
    /// The window this session shows in; a tab it opens joins that window (S-037).
    @ObservationIgnored weak var window: NSWindow?
    /// This window's own openWindow, for the tabs it opens (S-037, S-055).
    @ObservationIgnored var openWindowAction: OpenWindowAction?
    /// Where a tab opened on a table goes once connected (S-037).
    @ObservationIgnored var pendingPlace: Place?
    /// Names this window to agents when its connection isn't saved (S-063).
    @ObservationIgnored let agentID = UUID()

    // MARK: Connected

    @ObservationIgnored private(set) var client: DatabaseClient?
    /// The Connection Lost sheet (S-050): shown when a statement or a keep-alive ping finds the connection gone.
    var connectionLost = false
    var isReconnecting = false
    /// Why Reconnect failed, under the sheet's text.
    var reconnectProblem: DatabaseError?
    /// Pings the server while idle (Settings > Network).
    @ObservationIgnored var keepAliveTask: Task<Void, Never>?
    /// Seconds between pings for the self-test, in place of the setting.
    @ObservationIgnored var keepAliveOverride: Duration?
    /// The details this window connected with; favorites are matched on their server and user.
    private(set) var connectedDetails: ConnectionDetails?
    /// Set when connecting. Favorites live there, shared by every window.
    @ObservationIgnored private(set) weak var model: AppModel?
    var serverDescription = ""
    /// How this window's connection is encrypted; nil without SSL (S-058).
    var encryption: Encryption?
    var connectionName = ""
    var databases: [String] = []
    var database: String? {
        didSet {
            guard database != oldValue else { return }
            let left = placeBeingLeft()
            databaseChanged()
            noteVisit(leaving: left)
        }
    }
    var objects: [DBObject] = []
    var objectFilter = ""
    var isLoadingObjects = false
    var browseError: DatabaseError?
    /// Why the Routines section is missing, when only the routines failed to load.
    var routinesProblem: DatabaseError?
    var selectedObjectID: String? {
        didSet {
            // The sidebar's selection follows unless it already holds the object (S-022).
            if let id = selectedObjectID { if !sidebarSelection.contains(id) { sidebarSelection = [id] } } else { sidebarSelection = [] }
            guard selectedObjectID != oldValue else { return }
            let left = placeBeingLeft()
            if !isNavigating { reloadCurrentView() }
            noteVisit(leaving: left)
        }
    }
    /// Every object selected in the sidebar (⇧-click); the detail shows `selectedObjectID`.
    var sidebarSelection: Set<String> = []
    /// The object whose name is being edited in the sidebar (Rename Table, S-022).
    var renamingObjectID: String?
    var renameText = ""
    /// The Duplicate Table sheet (S-022).
    var tableDuplicator: TableDuplicator?
    /// The Show Create Statement sheet (S-028).
    var createStatementSheet: CreateStatementSheetModel?
    /// The Export sheet (S-041).
    var exporter: Exporter?
    /// The Import sheet (S-044).
    var importer: Importer?
    /// The Save Query sheet (S-034).
    var saveQueryDraft: SaveQueryDraft?
    /// The window's one alert: Empty/Delete Table and Delete Database asked first,
    /// or a notice that something finished or failed (`WindowAlert`).
    var alert: WindowAlert?
    /// Table > Maintenance (S-029): the operation running; its result is a notice.
    var runningTableOperation: TableOperation?
    /// A table opens on Content, as in Sequel Pro, unless Settings > General names
    /// another first view (S-054); the order stays Structure first (S-037).
    var view: DetailView = Preferences.firstView {
        didSet {
            guard view != oldValue else { return }
            if !isNavigating { reloadCurrentView(force: false) }
            noteVisit(leaving: nil)
        }
    }
    /// Back and Forward: every database, table and view shown (S-017, S-038).
    var history = History<Place>()
    /// The place on screen, so leaving it can be recorded.
    @ObservationIgnored var shownPlace: Place?
    /// True while Back, Forward or a followed link changes the table and view
    /// together, so only one load starts.
    @ObservationIgnored var isNavigating = false

    let structure = StructureController()
    let content = ContentController(pageSize: { AppModel.pageSize })
    let foreignKeys = ForeignKeysController()
    let triggers = TriggersController()
    /// The Field Editor sheet (S-012), for a Content cell or a Query result.
    var fieldEditor: FieldEditor?
    /// The Bit Editor sheet (S-013), for a BIT cell.
    var bitEditor: BitEditor?
    /// The Go to Database sheet (S-020).
    var goToDatabase: DatabaseFinder?
    /// The New Database sheet (S-018).
    var newDatabase: DatabaseCreator?
    /// The New Table sheet (S-021).
    var newTable: TableCreator?
    /// New View, New Procedure, New Function and their Edit sheets (S-030).
    var definitionDraft: DefinitionDraft?
    /// The Duplicate Database, Rename Database or Change Character Set sheet (S-019).
    var databaseEditor: DatabaseEditor?
    /// Database > View Using Encoding (S-056); kept across a reconnect.
    var viewEncoding: ViewEncoding = .utf8mb4
    /// Save Connection File… and Save Session… (S-055): the options sheet.
    var connectionFileDraft: ConnectionFileDraft?
    /// Open… on an encrypted file: its password sheet.
    var fileUnlock: FileUnlock?
    /// The Server Processes window this window opened (S-053).
    var processListID: UUID?
    /// The Server Variables sheet (S-052).
    var serverVariables: VariableList?
    /// The User Accounts sheet (S-051).
    var userManager: UserManager?
    let info = InfoController()
    let query = QueryController()
    /// The query editor's completion catalog: tables and columns by database (S-031).
    @ObservationIgnored var completionTables: [String: [CompletionCatalog.Table]] = [:]
    @ObservationIgnored var loadingCompletionDatabases: Set<String> = []
    /// The Database Information panel (⌥⌘I) and its tools.
    let databaseInfo = DatabaseInfo()
    var showsDatabaseInfo = false {
        didSet { if showsDatabaseInfo, !oldValue { loadDatabaseInfo() } }
    }

    /// The load the current view started; the self-test awaits it.
    @ObservationIgnored var currentLoad: Task<Void, Never>?

    var selectedObject: DBObject? { objects.first { $0.id == selectedObjectID } }

    var visibleObjects: [DBObject] { objects.filter { $0.matches(objectFilter) } }

    /// The window title: the object's name, or "Query".
    var title: String {
        if phase != .connected { return "New Connection" }
        if view == .query { return "Query" }
        return selectedObject?.name ?? (database ?? connectionName)
    }

    /// Always shown, so the toolbar height never changes: "quarry_demo · Local".
    var subtitle: String {
        guard phase == .connected else { return "Not Connected" }
        // S-068: a file has one database, so the line names the file and SQLite: "demo.sqlite · SQLite 3.51".
        if isSQLite { return [connectionName, serverDescription, isReadOnly ? "Read Only" : nil].compactMap { $0 }.joined(separator: " · ") }
        return [database, connectionName, encryption == nil ? nil : "SSL"].compactMap { $0 }.joined(separator: " · ")
    }

    /// The window has a SQLite file open (S-068).
    var isSQLite: Bool { phase == .connected && connectedDetails?.engine == .sqlite }

    /// The connected engine, for SQL builders and sheet drafts; MySQL until a SQLite file is connected.
    var engine: Engine { isSQLite ? .sqlite : .mysql }

    /// A SQLite file opened with Open Read Only: edits gray out (S-068).
    var isReadOnly: Bool { isSQLite && connectedDetails?.readOnly == true }

    // MARK: Connecting

    func show(saved: SavedConnection?) {
        selectedSaved = saved?.uid
        selectedFavorite = nil
        form = saved?.details ?? ConnectionDetails()
        connectProblem = nil
        testResult = nil
    }

    /// Fills the form from a favorite database; Connect opens that database.
    func show(favorite: FavoriteDatabase) {
        selectedSaved = nil
        selectedFavorite = favorite.uid
        form = favorite.details
        connectProblem = nil
        testResult = nil
    }

    // MARK: Favorite databases (S-060)

    /// The databases starred on this window's server and user.
    var favoriteDatabases: Set<String> { model?.favoriteNames(on: connectedDetails) ?? [] }

    var isFavoriteDatabase: Bool { database.map(favoriteDatabases.contains) ?? false }

    /// Add to Favorites / Remove from Favorites (⌘D).
    func toggleFavoriteDatabase() {
        guard !isSQLite, let model, let details = connectedDetails, let database else { return }
        model.toggleFavorite(database, on: details)
    }

    /// Connects with the form's details. Errors stay under the form.
    func connect(model: AppModel?) {
        guard phase == .disconnected else { return }
        if let problem = form.problem {
            connectProblem = DatabaseError(message: problem)
            return
        }
        connectProblem = nil
        testResult = nil
        phase = .connecting
        let details = form
        self.model = model
        connectTask = Task {
            do {
                let client = try await DatabaseClient.connect(details)
                guard !Task.isCancelled, phase == .connecting else {
                    await client.close()
                    return
                }
                attach(client)
                serverDescription = client.serverDescription
                encryption = client.encryption
                connectionName = details.displayName
                connectedDetails = details
                phase = .connected
                model?.markUsed(selectedSaved)
                model?.markFavoriteUsed(selectedFavorite)
                // A SQLite file has one database, main (S-068).
                await loadDatabases(select: details.engine == .sqlite ? SQLiteDialect.mainDatabase
                                    : details.driverConfiguration.database)
                if let place = pendingPlace {
                    pendingPlace = nil
                    _ = await go(to: place)
                }
                await showFirstTable()
            } catch let question as SSHQuestion {
                guard !Task.isCancelled, phase == .connecting else { return }
                phase = .disconnected
                ask(question, retry: .connect)
            } catch {
                guard !Task.isCancelled, phase == .connecting else { return }
                connectProblem = DatabaseError.from(error)
                phase = .disconnected
            }
        }
    }

    /// Makes `client` this window's connection: watches for it being lost and keeps it alive (S-050).
    func attach(_ client: DatabaseClient) {
        self.client = client
        // S-056: a reconnect keeps the encoding chosen; a new connection starts on UTF-8.
        if viewEncoding != .utf8mb4 {
            let encoding = viewEncoding
            Task { try? await client.setViewEncoding(encoding) }
        }
        Task { [weak self] in
            await client.untilLost()
            guard await client.wasLost else { return }
            self?.lost(client)
        }
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.keepAliveOverride ?? AppModel.keepAliveInterval.map { Duration.seconds($0) }
                try? await Task.sleep(for: interval ?? .seconds(5))
                guard !Task.isCancelled, self?.client === client else { break }
                guard interval != nil else { continue }
                await client.keepAlive()
                if client.isClosed { break }
            }
        }
    }

    /// Awaits the connection the last `connect` started (self-test).
    func waitForConnect() async { await connectTask?.value }

    func cancelConnect() {
        connectTask?.cancel()
        phase = .disconnected
    }

    /// Tries the form's details without leaving the Connect page.
    func testConnection() async {
        if let problem = form.problem {
            testResult = .failure(DatabaseError(message: problem))
            return
        }
        isTesting = true
        defer { isTesting = false }
        do {
            let client = try await DatabaseClient.connect(form)
            testResult = .success("Connected to \(client.serverDescription)"
                + (client.encryption.map { " with SSL (\($0.version))" } ?? ""))
            await client.close()
        } catch let question as SSHQuestion {
            ask(question, retry: .test)
        } catch {
            testResult = .failure(DatabaseError.from(error))
        }
    }

    /// Closes the connection and returns to the Connect page with the form kept.
    func disconnect() {
        stopProcessList()
        viewEncoding = .utf8mb4
        let old = client
        client = nil
        encryption = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        connectionLost = false
        isReconnecting = false
        reconnectProblem = nil
        Task { await old?.close() }
        phase = .disconnected
        connectedDetails = nil
        databases = []
        database = nil
        objects = []
        objectFilter = ""
        browseError = nil
        routinesProblem = nil
        query.reset()
        completionTables = [:]
        history.removeAll()
        shownPlace = nil
        databaseInfo.reset()
    }

    // MARK: Menus

    var menuSnapshot: MenuState.Snapshot {
        let actions = objectActions()
        return MenuState.Snapshot(
            phase: phase,
            isSQLite: isSQLite,
            isReadOnly: isReadOnly,
            selectedSaved: phase == .disconnected ? selectedSaved : nil,
            view: view,
            hasDatabase: database != nil,
            hasObject: selectedObject != nil,
            canRunQuery: phase == .connected && !query.isRunning,
            canCancelQuery: query.isRunning && !query.isCancelling,
            canShowCompletions: phase == .connected && view == .query,
            hasQueryHistory: !queryHistory.isEmpty,
            hasQueryText: query.hasText,
            showsDatabaseInfo: showsDatabaseInfo,
            viewEncoding: viewEncoding,
            isFavoriteDatabase: isFavoriteDatabase,
            canEditDatabase: editableDatabase != nil,
            canDuplicateDatabase: duplicableDatabase != nil,
            runnableTools: Set(DatabaseInfo.Tool.tools(for: engine).filter {
                databaseInfo.canRun($0) || (!databaseInfo.isLoaded && $0 != .repair && !($0.writesToFile && isReadOnly))
            }),
            hasPreviousPage: view == .content && content.paging.hasPrevious && !content.isLoading,
            hasNextPage: view == .content && content.paging.hasNext && !content.isLoading,
            canAddRow: view == .structure ? structure.canAddField : view == .content && content.canAddRow,
            canDuplicateRow: view == .structure ? structure.canDuplicateField : view == .content && content.canDuplicateRow,
            canDeleteRows: view == .structure ? structure.canDeleteFields && structure.gridHasFocus
                : view == .content && content.canDeleteRows && content.gridHasFocus,
            selectedRowCount: view == .structure ? structure.selection.count : content.selection.count,
            canEditField: view == .structure && structure.canEditField,
            canMoveFieldUp: view == .structure && structure.canMove(by: -1),
            canMoveFieldDown: view == .structure && structure.canMove(by: 1),
            canAddIndex: view == .structure && structure.canAddIndex,
            indexGridHasFocus: view == .structure && structure.indexGridHasFocus,
            canDeleteIndexes: view == .structure && structure.canDeleteIndexes && structure.indexGridHasFocus,
            deleteIndexTitle: Self.deleteIndexMenuTitle(structure.selectedIndexNames.count),
            canAddForeignKey: view == .foreignKeys && foreignKeys.canAdd,
            canDeleteForeignKeys: view == .foreignKeys && foreignKeys.canDelete && foreignKeys.gridHasFocus,
            deleteForeignKeyTitle: ForeignKeysController.deleteMenuTitle(foreignKeys.selectedNames.count),
            canAddTrigger: view == .triggers && triggers.canAdd,
            canEditTrigger: view == .triggers && triggers.canEdit,
            canDeleteTriggers: view == .triggers && triggers.canDelete && triggers.gridHasFocus,
            deleteTriggerTitle: TriggersController.deleteMenuTitle(triggers.selectedNames.count),
            canResetAutoIncrement: view == .info && info.canResetAutoIncrement,
            canFilter: phase == .connected && selectedObject.map { $0.kind == .table || $0.kind == .view } ?? false,
            canSaveFilter: phase == .connected && filterPlace != nil && content.filter.canSave,
            savedFilters: savedFilters.map { SavedFilterItem(id: $0.uid, name: $0.name) },
            isFiltered: view == .content && content.isFiltered,
            canOpenReferencedRow: canOpenReferencedRow,
            openInNewTabTitle: Self.openInNewTabTitle(selectedObject?.kind),
            canGoBack: phase == .connected && history.canGoBack,
            canGoForward: phase == .connected && history.canGoForward,
            creatableKinds: Set(ObjectKind.allCases.filter(actions.canCreate)),
            renameTitle: actions.renameTitle,
            canRenameTable: actions.rename != nil && renamingObjectID == nil,
            canDuplicateTable: actions.duplicate != nil,
            editDefinitionTitle: actions.editDefinitionTitle,
            canEditDefinition: actions.definition != nil && definitionDraft == nil,
            emptyTitle: actions.emptyTitle,
            canEmptyTables: !actions.empty.isEmpty,
            deleteTitle: actions.deleteTitle,
            canDeleteTables: !actions.delete.isEmpty,
            canShowCreateStatement: !createStatementTargets().isEmpty && createStatementSheet == nil,
            canExport: canExport,
            canImport: canImport,
            tableOperationTitles: Dictionary(uniqueKeysWithValues: TableOperation.allCases.compactMap { operation in
                tableOperationTitle(operation).map { (operation, $0) }
            }))
    }
}
