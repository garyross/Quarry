import Foundation
import Observation
import QuarryKit

/// The Content view (⌘2): one page of a table's rows, sorted and paged on the
/// server. Its own `@Observable`, so Content redraws without touching the rest
/// of the window (architecture review, 2026-11-18).
@Observable
package final class ContentController {
    /// Rows per page, read each time a table opens (Settings > General changes it).
    private let pageSize: () -> Int

    package private(set) var grid = GridData.empty
    package private(set) var paging = Paging(total: 0, pageSize: LoadState.defaultPageSize)
    package private(set) var sortColumn: String?
    package private(set) var ascending = true
    package private(set) var load = LoadState()
    /// The page's columns as the server described them (names, primary key).
    package private(set) var columns: [ResultColumn] = []
    /// SQLite tables with no primary key (S-069): the name that reaches the rowid
    /// ("rowid"), and each shown row's rowid, which edits find the row by. Nil and empty otherwise.
    package private(set) var rowIDName: String?
    package private(set) var rowIDs: [CellValue] = []
    /// Why the last edit failed; shown above the status bar until dismissed.
    package var editError: DatabaseError?
    /// The grid's selected rows (page indexes).
    package var selection = IndexSet()
    /// True while the grid itself (not a cell's editor) has keyboard focus, so ⌘⌫ deletes rows.
    package var gridHasFocus = false
    /// A row added or duplicated but not saved yet (S-010).
    package private(set) var draft: Draft?
    /// Asks the grid to edit a cell; a new `id` each time.
    package private(set) var editRequest: EditRequest?
    /// Rows waiting for the delete alert's answer.
    package var pendingDelete: IndexSet?
    /// The filter: its rules, the clause the page was loaded with, saved filters (S-014, S-015, S-061, S-062).
    package let filter = ContentFilter()
    /// Rows in the whole table, while a filter narrows `paging.total`.
    package private(set) var unfilteredTotal = 0

    package init(pageSize: @escaping () -> Int) {
        self.pageSize = pageSize
        filter.search = { [unowned self] in
            paging = Paging(total: paging.total, pageSize: paging.pageSize, page: 0)
            return reload()
        }
    }

    package struct Draft: Equatable {
        package let row: Int
        /// Columns people set (or Duplicate copied); the INSERT names only these,
        /// so the server fills the rest with its defaults.
        package var setColumns: Set<Int>
    }

    package struct EditRequest: Equatable {
        package let row: Int
        package let column: Int
        package let id = UUID()
    }

    package var isLoading: Bool { load.isLoading }

    /// What the page shows: the table, its database, and the connection.
    private struct Target {
        package let client: DatabaseClient
        package let database: String
        package let object: DBObject
        package var key: String { "\(database)/\(object.id)" }
    }

    @ObservationIgnored private var target: Target?
    /// SHOW FULL COLUMNS for the shown table: defaults for new rows, headers for an empty table.
    @ObservationIgnored private var fields: (key: String, list: [FieldInfo])?
    /// The shown table's foreign keys, one link per field (S-017).
    @ObservationIgnored private var fieldLinks: (key: String, links: [String: ForeignKeyLink])?
    /// Filter, sort and page to show the next time this table opens: following
    /// a foreign key, or Back (S-017). Taken once.
    @ObservationIgnored package var pendingRestore: Saved?

    /// What Back brings back on a table's Content.
    package struct Saved: Equatable {
        /// "database/table:name", as `load.loadedFor`.
        package var key: String
        package var filter: FilterTree
        package var appliedClause: String?
        package var savedFilterName: String?
        package var sortColumn: String?
        package var ascending = true
        package var page = 0

        package init(key: String, filter: FilterTree, appliedClause: String? = nil, savedFilterName: String? = nil,
                     sortColumn: String? = nil, ascending: Bool = true, page: Int = 0) {
            self.key = key
            self.filter = filter
            self.appliedClause = appliedClause
            self.savedFilterName = savedFilterName
            self.sortColumn = sortColumn
            self.ascending = ascending
            self.page = page
        }
    }

    /// The table's fields changed (S-023): load it again the next time Content shows.
    package func invalidate() {
        fields = nil
        fieldLinks = nil
        load = LoadState()
    }

    /// Clears everything (a new database, a disconnect).
    package func reset() {
        target = nil
        grid = .empty
        paging = Paging(total: 0, pageSize: pageSize())
        sortColumn = nil
        ascending = true
        load = LoadState()
        columns = []
        editError = nil
        filter.detach()
        unfilteredTotal = 0
        clearRowState()
    }

    private func clearRowState() {
        rowIDName = nil
        rowIDs = []
        selection = []
        draft = nil
        editRequest = nil
        pendingDelete = nil
    }

    /// Shows `object`. A new object starts unsorted on the first page; the same
    /// one keeps its sort and page. Returns nil when nothing needs loading.
    package func show(_ object: DBObject, in database: String, client: DatabaseClient, force: Bool) -> Task<Void, Never>? {
        let next = Target(client: client, database: database, object: object)
        if let restore = pendingRestore, restore.key == next.key {
            pendingRestore = nil
            apply(restore)
        } else if next.key != load.loadedFor || next.key != target?.key {
            sortColumn = nil
            ascending = true
            paging = Paging(total: 0, pageSize: pageSize())
            filter.reset()
            unfilteredTotal = 0
        } else if !force {
            return nil
        }
        target = next
        filter.show(engine: client.dialect.engine)
        editError = nil
        return reload()
    }

    /// This table's filter, sort and page, for Back.
    package var saved: Saved? {
        guard let target else { return nil }
        return Saved(key: target.key, filter: filter.draft, appliedClause: filter.appliedClause, savedFilterName: filter.savedName,
                     sortColumn: sortColumn, ascending: ascending, page: paging.page)
    }

    private func apply(_ restore: Saved) {
        sortColumn = restore.sortColumn
        ascending = restore.ascending
        // A total that holds the page; the load clamps it to the real one.
        paging = Paging(total: (restore.page + 1) * paging.pageSize, pageSize: paging.pageSize, page: restore.page)
        filter.restore(restore.filter, clause: restore.appliedClause, savedName: restore.savedFilterName)
        unfilteredTotal = 0
        clearRowState()
    }

    // MARK: Foreign keys (S-017)

    /// The link from a page column, when its field starts a foreign key.
    package func link(column: Int) -> ForeignKeyLink? {
        guard let target, column < columns.count, let fieldLinks, fieldLinks.key == target.key else { return nil }
        return fieldLinks.links[columns[column].name]
    }

    /// The link a cell's arrow follows: a saved row's value, not NULL.
    package func link(row: Int, column: Int) -> ForeignKeyLink? {
        guard row < grid.rows.count, column < grid.rows[row].count, draft == nil,
              ForeignKeyLink.canFollow(grid.rows[row][column]) else { return nil }
        return link(column: column)
    }

    /// The arrow's hover help: "Open the customers row where id = 3".
    package func linkHelp(row: Int, column: Int) -> String? {
        guard let target, let link = link(row: row, column: column) else { return nil }
        return link.help(for: grid.rows[row][column], from: target.database)
    }

    /// The selected row's links, left to right: Open Referenced Row.
    package func followableLinks(row: Int) -> [Int] {
        columns.indices.filter { link(row: row, column: $0) != nil }
    }

    /// The shown table's links, loaded once per table; a view has none.
    private func links(for target: Target) async -> [String: ForeignKeyLink] {
        if let fieldLinks, fieldLinks.key == target.key { return fieldLinks.links }
        guard target.object.kind == .table,
              let keys = try? await target.client.foreignKeys(of: target.object.name, in: target.database) else { return [:] }
        let links = ForeignKeyLink.links(keys)
        fieldLinks = (target.key, links)
        return links
    }

    /// Clicking a header: sort on the server and go back to the first page.
    package func sort(by column: String, ascending: Bool) -> Task<Void, Never>? {
        sortColumn = column
        self.ascending = ascending
        paging = Paging(total: paging.total, pageSize: paging.pageSize, page: 0)
        return reload()
    }

    // MARK: Filtering (ContentFilter)

    package var isFiltered: Bool { filter.isFiltered }

    /// The shown table's rows under the applied filter and sort, for Export's
    /// "Filtered content" source (S-042); nil when Content shows no table or view.
    package var exportSource: (database: String, source: DataSource, rows: Int)? {
        guard let target, target.object.kind == .table || target.object.kind == .view else { return nil }
        return (target.database,
                DataSource(table: target.object.name, condition: filter.appliedClause, orderBy: sortColumn, ascending: ascending),
                paging.total)
    }

    /// The status bar's count: "Rows 1–1,000 of 48,213", or "312 of 100,000 rows" with a filter.
    package var statusLabel: String {
        if load.error != nil { return isFiltered ? "The filter failed" : "Rows couldn\u{2019}t load" }
        return isFiltered ? paging.filteredLabel(unfiltered: unfilteredTotal) : paging.label
    }

    /// Opens a saved filter; one that names columns the table no longer has says so above the status bar.
    @discardableResult
    package func open(_ tree: FilterTree, named name: String) -> Task<Void, Never>? {
        do {
            return try filter.open(tree, named: name)
        } catch {
            editError = DatabaseError.from(error)
            return nil
        }
    }

    package func move(by pages: Int) -> Task<Void, Never>? {
        let moved = paging.moved(by: pages)
        guard moved.page != paging.page else { return nil }
        paging = moved
        return reload()
    }

    /// Loads the current page again with the current sort.
    @discardableResult
    package func reload() -> Task<Void, Never>? {
        guard let target else { return nil }
        return Task { await loadPage(target) }
    }

    private func loadPage(_ target: Target) async {
        await withLoading({ self.load.isLoading = $0 }) {
            do {
                let object = target.object
                let condition = filter.appliedClause
                let total = try await target.client.rowCount(of: object.name, in: target.database, where: condition)
                let unfiltered = condition == nil ? total : try await target.client.rowCount(of: object.name, in: target.database)
                let paging = Paging(total: total, pageSize: self.paging.pageSize, page: self.paging.page)
                // Once per table: new filter rules start on the auto-increment or an indexed column.
                let tableFields = await fields(for: target)
                let rowID = Self.rowIDName(for: target, fields: tableFields)
                var page = try await target.client.page(of: object.name, in: target.database, where: condition,
                                                        orderBy: sortColumn, ascending: ascending,
                                                        offset: paging.offset, limit: paging.pageSize, rowID: rowID)
                var ids: [CellValue] = []
                if rowID != nil, !page.columns.isEmpty {
                    // The rowid comes first; the grid never shows it.
                    ids = page.rows.map { $0.first ?? .null }
                    page.columns.removeFirst()
                    page.rows = page.rows.map { Array($0.dropFirst()) }
                }
                let links = await links(for: target)
                guard self.target?.key == target.key else { return }
                self.paging = paging
                unfilteredTotal = unfiltered
                if page.columns.isEmpty, let fields = await fields(for: target) {
                    // The server names columns only with rows; an empty table takes them from its fields.
                    columns = fields.map { ResultColumn(name: $0.name, typeName: $0.baseType, isPrimaryKey: $0.key == "PRI",
                                                        bitWidth: $0.bitWidth) }
                    grid = GridData(columns: fields.enumerated().map {
                        GridData.Column(id: "c\($0.offset)", title: $0.element.name, sortKey: $0.element.name,
                                        bitWidth: $0.element.bitWidth)
                    })
                } else {
                    grid = GridData(page, sortable: true)
                    columns = page.columns
                }
                for index in grid.columns.indices where index < columns.count {
                    grid.columns[index].isLinked = links[columns[index].name] != nil
                }
                rowIDName = rowID
                rowIDs = ids
                if target.client.dialect.engine == .sqlite { markSQLiteColumns(object) }
                filter.tableLoaded(columns: columns.map(\.name), fields: tableFields ?? [])
                // The grid keeps its selection across a reload; only the new row and requests go.
                draft = nil
                editRequest = nil
                pendingDelete = nil
                load = LoadState(loadedFor: target.key)
            } catch {
                guard self.target?.key == target.key else { return }
                // The filter stays as typed (S-061), so a mistake in a WHERE clause can be fixed.
                // The old rows go (they no longer match what the bar says); the headers stay.
                grid = GridData(columns: grid.columns)
                selection = []
                load = LoadState(error: DatabaseError.from(error))
            }
        }
    }

    // MARK: SQLite (S-069)

    /// The rowid's name for a SQLite table with no primary key (a WITHOUT ROWID table always has one).
    private static func rowIDName(for target: Target, fields: [FieldInfo]?) -> String? {
        guard target.client.dialect.engine == .sqlite, target.object.kind == .table, let fields,
              !fields.contains(where: { $0.key == "PRI" }) else { return nil }
        return SQLiteDialect.rowIDName(avoiding: fields.map(\.name))
    }

    /// Cells stored with another type than their column's say so on hover; a view's say it can't be edited.
    private func markSQLiteColumns(_ object: DBObject) {
        for index in grid.columns.indices where index < columns.count {
            let type = columns[index].typeName
            grid.columns[index].affinity = type.isEmpty ? nil : SQLiteAffinity(type)
            if object.kind == .view { grid.columns[index].help = Self.sqliteViewHelp }
        }
    }

    package static let sqliteViewHelp = "Views in SQLite can’t be edited."

    /// How the shown table finds a row: Rows are found by rowid (no primary key).
    package var findsRowsByRowID: Bool { rowIDName != nil }

    /// The columns and values that find row `row` again: the page's, with the
    /// rowid as the only key column when the table has no primary key.
    private func key(for row: Int) -> (columns: [ResultColumn], values: [CellValue]) {
        let values = row < grid.rows.count ? grid.rows[row] : []
        guard let rowIDName, row < rowIDs.count else { return (columns, values) }
        let unkeyed = columns.map { column in
            var column = column
            column.isPrimaryKey = false
            return column
        }
        return (unkeyed + [ResultColumn(name: rowIDName, isPrimaryKey: true)], values + [rowIDs[row]])
    }

    // MARK: Editing (S-009)

    /// Cells edited inline: a table's short values. Long values, bytes and
    /// JSON open in the Field Editor instead (S-012).
    package func canEdit(row: Int, column: Int) -> Bool {
        canChange(row: row, column: column) && !opensFieldEditor(row: row, column: column)
    }

    /// Any cell of a table can be changed, inline or in the Field Editor.
    package func canChange(row: Int, column: Int) -> Bool {
        target?.object.kind == .table && target?.client.isReadOnly == false && row < grid.rows.count && column < grid.rows[row].count && column < columns.count
    }

    // MARK: Field Editor (S-012)

    /// The field's type ("text", "json", "varchar"), from SHOW FULL COLUMNS.
    package func fieldType(column: Int) -> String? {
        guard column < columns.count else { return nil }
        return fields?.list.first { $0.name == columns[column].name }?.baseType
    }

    /// True when double-clicking the cell opens the Field Editor.
    package func opensFieldEditor(row: Int, column: Int) -> Bool {
        guard row < grid.rows.count, column < grid.rows[row].count else { return false }
        if bitWidth(column: column) != nil { return true }
        return LongValue.opensFieldEditor(grid.rows[row][column], fieldType: fieldType(column: column))
    }

    /// A BIT column's width; its cells open in the Bit Editor (S-013).
    package func bitWidth(column: Int) -> Int? {
        guard column < columns.count else { return nil }
        return columns[column].bitWidth ?? fields?.list.first { $0.name == columns[column].name }?.bitWidth
    }

    /// The Bit Editor for a BIT cell; Saving runs the same UPDATE as an inline edit.
    package func bitEditor(row: Int, column: Int, save: @escaping (Int, Int, CellValue) -> Void) -> BitEditor? {
        guard row < grid.rows.count, column < grid.rows[row].count, let width = bitWidth(column: column) else { return nil }
        let field = fields?.list.first { $0.name == columns[column].name }
        return BitEditor(fieldName: columns[column].name, width: width, row: row, column: column,
                         value: grid.rows[row][column], isEditable: canChange(row: row, column: column) && !isLoading,
                         isNullable: field?.isNullable ?? false) { value in
            save(row, column, value)
        }
    }

    /// The text an edit starts with: the value, or nothing for NULL.
    package func editingText(row: Int, column: Int) -> String {
        grid.rows[row][column].plainText ?? ""
    }

    /// Saves a cell's new value with an UPDATE on the row's primary key, then
    /// reloads the page so the server's values show (defaults, triggers).
    /// A failed update shows the error and puts the old value back.
    /// `value` is the typed text, or `.null` from Set to NULL (S-011).
    @discardableResult
    package func edit(row: Int, column: Int, to value: CellValue) -> Task<Void, Never>? {
        guard let target, canChange(row: row, column: column) else { return nil }
        let old = grid.rows[row]
        // Unchanged: NULL over NULL, or the text the editor started with ("" for NULL).
        let unchanged = value.isNull ? old[column].isNull : value.plainText == editingText(row: row, column: column)
        if unchanged { return nil }
        if draft?.row == row {
            // A new row keeps its values until the row is saved.
            grid.rows[row][column] = value
            draft?.setColumns.insert(column)
            return nil
        }
        let found = key(for: row)
        let sql = RowEdit.updateSQL(database: target.database, table: target.object.name, columns: found.columns,
                                    row: found.values, changes: [column: value], engine: target.client.dialect.engine)
        editError = nil
        grid.rows[row][column] = value
        return Task {
            do {
                let result = try await target.client.run(sql)
                guard self.target?.key == target.key else { return }
                if result.affectedRows == 0 {
                    editError = DatabaseError(message: "No row was changed.",
                                              suggestion: "The value may equal the old one, or the row was changed or deleted elsewhere. The rows were reloaded.")
                }
                await loadPage(target)
            } catch {
                guard self.target?.key == target.key else { return }
                editError = DatabaseError.from(error)
                var rows = grid.rows
                if row < rows.count { rows[row] = old }
                grid = GridData(columns: grid.columns, rows: rows)
            }
        }
    }

    // MARK: Adding and deleting rows (S-010)

    package var isTable: Bool { target?.object.kind == .table }

    /// Rows can be added to a loaded table, one at a time.
    package var canAddRow: Bool {
        guard let target else { return false }
        return target.object.kind == .table && !target.client.isReadOnly && load.loadedFor == target.key
            && !columns.isEmpty && draft == nil
    }

    package var canDuplicateRow: Bool { canAddRow && selection.count == 1 && selection.first! < grid.rows.count }

    package var canDeleteRows: Bool {
        guard let target else { return false }
        return target.object.kind == .table && !target.client.isReadOnly && !selection.isEmpty && !isLoading
    }

    /// Adds a row with the table's defaults at the end of the page, or a copy of
    /// row `source`, and asks the grid to edit its first editable cell.
    @discardableResult
    package func addRow(copying source: Int? = nil) -> Task<Void, Never>? {
        guard let target, source == nil ? canAddRow : canDuplicateRow else { return nil }
        return Task {
            let fields = await fields(for: target) ?? []
            guard self.target?.key == target.key, draft == nil else { return }
            let field = { (index: Int) in fields.first { $0.name == self.columns[index].name } }
            var values = columns.indices.map { field($0).map(NewRow.initialValue) ?? .null }
            var set = Set<Int>()
            if let source, source < grid.rows.count {
                for index in columns.indices where field(index).map(NewRow.copiesValue) ?? true {
                    values[index] = grid.rows[source][index]
                    set.insert(index)
                }
            }
            let row = grid.rows.count
            grid = GridData(columns: grid.columns, rows: grid.rows + [values])
            if rowIDName != nil { rowIDs.append(.null) }
            draft = Draft(row: row, setColumns: set)
            selection = [row]
            editError = nil
            let first = columns.indices.first { index in
                canEdit(row: row, column: index) && !(field(index).map { !NewRow.copiesValue($0) } ?? false)
            }
            if let first { editRequest = EditRequest(row: row, column: first) }
        }
    }

    /// The grid ended editing a row: Return or clicking away saves a new row, Escape removes it.
    @discardableResult
    package func endRowEdit(row: Int, cancelled: Bool) -> Task<Void, Never>? {
        guard let draft, draft.row == row else { return nil }
        if cancelled {
            discardDraft()
            return nil
        }
        return saveDraft()
    }

    package func discardDraft() {
        guard let draft else { return }
        var rows = grid.rows
        if draft.row < rows.count { rows.remove(at: draft.row) }
        if draft.row < rowIDs.count { rowIDs.remove(at: draft.row) }
        self.draft = nil
        selection = []
        grid = GridData(columns: grid.columns, rows: rows)
    }

    /// INSERTs the new row, then shows what the server stored (auto_increment,
    /// expression defaults). A refused INSERT keeps the row for another try.
    @discardableResult
    package func saveDraft() -> Task<Void, Never>? {
        guard let target, let draft, draft.row < grid.rows.count else { return nil }
        let values = grid.rows[draft.row]
        let sql = RowEdit.insertSQL(database: target.database, table: target.object.name,
                                    values: draft.setColumns.sorted().map { (columns[$0].name, values[$0]) },
                                    engine: target.client.dialect.engine)
        editError = nil
        return Task {
            do {
                let id = try await target.client.insert(sql)
                guard self.target?.key == target.key else { return }
                let stored = try await storedRow(values, set: draft.setColumns, newID: id, target: target)
                self.draft = nil
                paging = Paging(total: paging.total + 1, pageSize: paging.pageSize, page: paging.page)
                if let stored, draft.row < grid.rows.count {
                    var rows = grid.rows
                    rows[draft.row] = stored
                    grid = GridData(columns: grid.columns, rows: rows)
                } else {
                    await loadPage(target)
                }
            } catch {
                guard self.target?.key == target.key else { return }
                editError = DatabaseError.from(error)
            }
        }
    }

    /// Reads back the inserted row by its primary key, when the key is known:
    /// the new auto_increment value, or key values people set. Nil otherwise.
    private func storedRow(_ values: [CellValue], set: Set<Int>, newID: UInt64, target: Target) async throws -> [CellValue]? {
        guard RowEdit.hasPrimaryKey(columns), let fields = await fields(for: target) else { return nil }
        var row = values
        for index in columns.indices where columns[index].isPrimaryKey {
            let field = fields.first { $0.name == columns[index].name }
            if let field, NewRow.isAutoIncrement(field), newID > 0, !set.contains(index) {
                row[index] = .text(String(newID))
            } else if !set.contains(index) {
                return nil
            }
        }
        let sql = "SELECT * FROM " + SQLQuote.qualified(target.database, target.object.name)
            + " WHERE " + RowEdit.whereClause(columns: columns, row: row, engine: target.client.dialect.engine) + " LIMIT 1"
        let result = try await target.client.run(sql)
        guard let stored = result.rows.first, stored.count == columns.count else { return nil }
        return stored
    }

    /// Delete Row: the selected rows go to the alert. An unsaved new row is just removed.
    package func requestDelete() {
        guard canDeleteRows else { return }
        var rows = IndexSet(selection.filter { $0 < grid.rows.count })
        if let draft, rows.contains(draft.row) {
            rows.remove(draft.row)
            discardDraft()
        }
        if !rows.isEmpty { pendingDelete = rows }
    }

    /// Deletes the rows the alert asked about, one DELETE each (… LIMIT 1 on MySQL), then reloads the page.
    @discardableResult
    package func confirmDelete() -> Task<Void, Never>? {
        guard let target, let rows = pendingDelete else { return nil }
        pendingDelete = nil
        let statements = rows.filter { $0 < grid.rows.count }.map { row in
            let found = key(for: row)
            return RowEdit.deleteSQL(database: target.database, table: target.object.name, columns: found.columns,
                                     row: found.values, engine: target.client.dialect.engine)
        }
        editError = nil
        return Task {
            var deleted = 0
            do {
                for sql in statements { deleted += try await target.client.run(sql).affectedRows ?? 0 }
                if deleted < statements.count {
                    editError = DatabaseError(message: "Deleted \(deleted) of \(statements.count) rows.",
                                              suggestion: "The others were changed or deleted elsewhere. The rows were reloaded.")
                }
            } catch {
                editError = DatabaseError.from(error)
            }
            guard self.target?.key == target.key else { return }
            await loadPage(target)
        }
    }

    /// The shown table's fields, loaded once per table.
    private func fields(for target: Target) async -> [FieldInfo]? {
        if let fields, fields.key == target.key { return fields.list }
        guard let list = try? await target.client.fields(of: target.object.name, in: target.database) else { return nil }
        fields = (target.key, list)
        return list
    }
}
