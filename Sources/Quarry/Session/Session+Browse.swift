import Foundation
import QuarryKit
import QuarryControllers

/// Databases, sidebar objects, and loading each detail view.
extension Session {
    func loadDatabases(select wanted: String?) async {
        guard let client else { return }
        do {
            databases = try await client.databases()
            browseError = nil
            if let wanted, databases.contains(wanted) {
                database = wanted
                await currentLoad?.value
            }
        } catch {
            browseError = DatabaseError.from(error)
        }
    }

    // MARK: New Database (S-018)

    /// Database > New Database… (⇧⌘N): opens the sheet and loads the server's character sets.
    func requestNewDatabase() {
        guard phase == .connected, !isSQLite, let client, newDatabase == nil else { return }
        let creator = DatabaseCreator(existing: databases)
        newDatabase = creator
        Task { await creator.load(client) }
    }

    /// Create in the sheet: runs CREATE DATABASE, then selects the new database.
    /// On an error the sheet stays open with the server's message.
    /// The returned task ends when the new database's objects have loaded (self-test).
    @discardableResult
    func createDatabase() -> Task<Void, Never>? {
        guard let client, let creator = newDatabase, creator.canCreate else { return nil }
        return Task {
            guard await creator.create(client) else { return }
            newDatabase = nil
            await loadDatabases(select: creator.name)
        }
    }

    // MARK: New Table (S-021)

    /// Table > New Table… (⌥⌘N) or the sidebar's + button: opens the sheet and
    /// loads the engines, character sets and the database's defaults.
    func requestNewTable() {
        guard objectActions().canCreate(.table), let client, let database, newTable == nil else { return }
        let names = objects.filter { $0.kind == .table || $0.kind == .view }.map(\.name)
        let creator = TableCreator(database: database, existing: names, engine: engine)
        newTable = creator
        Task { await creator.load(client) }
    }

    /// Create in the sheet: runs CREATE TABLE, then selects the table on Structure,
    /// as Sequel Pro did, so fields can be added next. On an error the sheet
    /// stays open with the server's message. The returned task ends when
    /// Structure has loaded (self-test).
    @discardableResult
    func createTable() -> Task<Void, Never>? {
        guard let client, let creator = newTable, creator.canCreate else { return nil }
        return Task {
            guard await creator.create(client) else { return }
            newTable = nil
            guard database == creator.database else { return }
            do {
                try await loadObjects(client, creator.database)
            } catch {
                browseError = DatabaseError.from(error)
            }
            let id = DBObject(name: creator.name, kind: .table).id
            if !(objects.first { $0.id == id }?.matches(objectFilter) ?? true) { objectFilter = "" }
            isNavigating = true
            selectedObjectID = id
            view = .structure
            isNavigating = false
            reloadCurrentView(force: true)
            await currentLoad?.value
        }
    }

    /// Called when `database` changes: clear what belonged to the old one, load the new list.
    func databaseChanged() {
        selectedObjectID = nil
        objects = []
        browseError = nil
        routinesProblem = nil
        objectFilter = ""
        structure.reset()
        content.reset()
        foreignKeys.reset()
        triggers.reset()
        info.reset()
        databaseInfo.reset()
        loadDatabaseInfo()
        guard let client, let database else { return }
        currentLoad = Task {
            await withLoading({ self.isLoadingObjects = $0 }) {
                do {
                    try await client.use(database)
                    try await loadObjects(client, database)
                } catch {
                    guard self.database == database else { return }
                    browseError = DatabaseError.from(error)
                }
            }
        }
    }

    /// Loads the Database Information panel's overview when it is open.
    func loadDatabaseInfo(force: Bool = false) {
        guard showsDatabaseInfo, let client, let database else { return }
        Task { await databaseInfo.load(database, client: client, force: force) }
    }

    /// Opens the panel and runs a tool there (menu items and the panel's buttons).
    /// Repair asks first; `confirmRepair` runs it.
    /// The returned task ends when the tool has finished (self-test, snapshots).
    @discardableResult
    func runTool(_ tool: DatabaseInfo.Tool) -> Task<Void, Never>? {
        guard let client, let database else { return nil }
        showsDatabaseInfo = true
        return Task {
            await databaseInfo.load(database, client: client)
            if tool == .repair {
                if databaseInfo.canRun(.repair) { databaseInfo.confirmingRepair = true }
            } else if tool == .vacuum {
                if databaseInfo.canRun(.vacuum) { databaseInfo.confirmingVacuum = true }
            } else {
                databaseInfo.run(tool, client: client)
                await databaseInfo.waitForTool()
            }
        }
    }

    func confirmRepair() {
        guard let client else { return }
        databaseInfo.run(.repair, client: client)
    }

    /// Vacuum's dialog answered (S-072). The returned task ends when it has run (self-test).
    @discardableResult
    func confirmVacuum() -> Task<Void, Never>? {
        guard let client else { return nil }
        databaseInfo.run(.vacuum, client: client)
        return Task { await databaseInfo.waitForTool() }
    }

    /// "Open in Query": puts SQL in the editor for people to review and run.
    func openInQuery(_ sql: String) {
        let current = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        query.text = current.isEmpty ? sql : query.text + "\n\n" + sql
        view = .query
    }

    /// Fills the sidebar. Tables and views must load; routines may fail on
    /// their own (an un-upgraded `mysql.proc`), and then the sidebar says why.
    func loadObjects(_ client: DatabaseClient, _ database: String) async throws {
        let tables = try await client.tablesAndViews(in: database)
        var routines: [DBObject] = []
        var problem: DatabaseError?
        do {
            routines = try await client.routines(in: database)
        } catch {
            problem = DatabaseError.from(error)
        }
        guard self.database == database else { return }
        objects = DBObject.sorted(tables + routines)
        routinesProblem = problem
        browseError = nil
    }

    /// Refresh (⇧⌘R): the database list, the sidebar, and the current view.
    func refresh() {
        guard phase == .connected else { return }
        let keep = selectedObjectID
        currentLoad = Task {
            await loadDatabases(select: nil)
            if let client, let database {
                do {
                    try await loadObjects(client, database)
                } catch {
                    browseError = DatabaseError.from(error)
                }
            }
            if objects.contains(where: { $0.id == keep }) { selectedObjectID = keep }
            loadDatabaseInfo(force: true)
            // currentLoad is still this task; when the view starts no load,
            // awaiting it would wait on itself forever (docs/FIXLOG.md).
            currentLoad = nil
            reloadCurrentView(force: true)
            await currentLoad?.value
        }
    }

    /// Loads the current view for the selected object, unless it already shows it.
    func reloadCurrentView(force: Bool = true) {
        guard phase == .connected, let client, let database else { return }
        let object = selectedObject
        guard let object, view.applies(to: object.kind) else { return }
        let task: Task<Void, Never>? = switch self.view {
        case .content: content.show(object, in: database, client: client, force: force)
        case .structure: structure.show(object, in: database, client: client, force: force)
        case .foreignKeys: foreignKeys.show(object, in: database, client: client, force: force)
        case .triggers: triggers.show(object, in: database, client: client, force: force)
        case .info: info.show(object, in: database, client: client, force: force)
        case .query: nil
        }
        if let task { currentLoad = task }
    }

    // MARK: Content paging and sorting

    /// Clicking a header: sort on the server and go back to the first page.
    func sortContent(by column: String, ascending: Bool) {
        if let task = content.sort(by: column, ascending: ascending) { currentLoad = task }
    }

    /// Saves an inline edit (S-009); the self-test awaits `currentLoad`.
    func editContent(row: Int, column: Int, to value: CellValue) {
        if let task = content.edit(row: row, column: column, to: value) { currentLoad = task }
    }

    // MARK: Field Editor (S-012)

    /// Opens a Content cell in the Field Editor; `typed` carries an inline edit over.
    func openFieldEditor(row: Int, column: Int, typed: String? = nil) {
        if let bits = content.bitEditor(row: row, column: column, save: { [weak self] row, column, value in
            self?.bitEditor = nil
            self?.saveFieldEditor(row: row, column: column, value: value)
        }) {
            bitEditor = bits
            return
        }
        fieldEditor = content.fieldEditor(row: row, column: column, typed: typed) { [weak self] row, column, value in
            self?.saveFieldEditor(row: row, column: column, value: value)
        }
    }

    /// Save in the Field Editor: the same UPDATE as an inline edit; a new row is then saved.
    func saveFieldEditor(row: Int, column: Int, value: CellValue) {
        fieldEditor = nil
        editContent(row: row, column: column, to: value)
        if content.draft?.row == row { endRowEdit(row: row, cancelled: false) }
    }

    // MARK: Rows (S-010); the self-test awaits `currentLoad`.

    func addRow() {
        view = .content
        if let task = content.addRow() { currentLoad = task }
    }

    func duplicateRow() {
        guard let source = content.selection.first else { return }
        if let task = content.addRow(copying: source) { currentLoad = task }
    }

    /// Ends editing a row in the grid: saves or removes a new row.
    func endRowEdit(row: Int, cancelled: Bool) {
        if let task = content.endRowEdit(row: row, cancelled: cancelled) { currentLoad = task }
    }

    /// Delete Row asks first; the alert calls `confirmDeleteRows`.
    func deleteRows() { content.requestDelete() }

    func confirmDeleteRows() {
        if let task = content.confirmDelete() { currentLoad = task }
    }

    /// Filter (S-014): the bar's filter, from the first page.
    func applyFilter() {
        if let task = content.filter.apply() { currentLoad = task }
    }

    func clearFilter() {
        if let task = content.filter.clear() { currentLoad = task }
    }

    /// Table > Filter Content: Content, with the filter's value field focused.
    func focusContentFilter() {
        view = .content
        content.filter.requestFocus()
    }

    /// Table > Add Filter Rule (⇧⌘F) and Add Filter Group (⌥⇧⌘F), on the focused rule (S-015).
    func addFilterRule() {
        view = .content
        content.filter.addRule()
    }

    func addFilterGroup() {
        view = .content
        content.filter.addGroup()
    }

    /// Table > Add WHERE Clause (⌃⌥⌘F): a rule typed as SQL (S-061).
    func addTypedClause() {
        view = .content
        content.filter.addTypedClause()
    }

    // MARK: Saved filters (S-062)

    /// The table Content shows, as saved filters know it: server and user, database, table.
    var filterPlace: SavedFilter.Place? {
        guard let details = connectedDetails, let database, let object = selectedObject,
              object.kind == .table || object.kind == .view else { return nil }
        return SavedFilter.Place(serverKey: FavoriteDatabase.serverKey(for: details), database: database, table: object.name)
    }

    /// The filters saved on the shown table, by name.
    var savedFilters: [SavedFilter] { model?.savedFilters(on: filterPlace) ?? [] }

    /// Table > Save Filter… (⌥⌘S) and the All line's Save button.
    func requestSaveFilter() {
        guard filterPlace != nil else { return }
        view = .content
        content.filter.requestSave()
    }

    /// The Save Filter alert's Save: keeps every rule, set or not.
    func saveFilter(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let model, let place = filterPlace, !name.isEmpty, content.filter.canSave else { return }
        model.saveFilter(content.filter.draft, named: name, on: place)
        content.filter.didSave(as: name)
    }

    func openSavedFilter(_ uid: UUID) {
        guard let saved = savedFilters.first(where: { $0.uid == uid }), let tree = saved.filter else { return }
        view = .content
        if let task = content.open(tree, named: saved.name) { currentLoad = task }
    }

    func deleteSavedFilter(_ uid: UUID) {
        model?.deleteSavedFilter(uid)
    }

    func movePage(by pages: Int) {
        if let task = content.move(by: pages) { currentLoad = task }
    }
}
