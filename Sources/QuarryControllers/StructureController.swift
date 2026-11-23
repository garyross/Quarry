import Foundation
import Observation
import QuarryKit

/// Structure (⌘1): a table's fields and indexes, and editing its fields (S-023).
/// Every change is a `TableChange` run through `perform`: one ALTER TABLE on
/// MySQL, ALTER TABLE or a rebuild on SQLite (S-070). On an error the grid goes
/// back to what the server has and the message shows above the status bar.
@Observable
package final class StructureController {
    package init() {}

    package private(set) var fields = GridData.empty
    package private(set) var indexes = GridData.empty
    package private(set) var load = LoadState()
    /// The fields as Structure edits them, in table order.
    package private(set) var definitions: [FieldDefinition] = []
    package var editError: DatabaseError?
    package var selection = IndexSet()
    package var gridHasFocus = false
    /// Field names waiting on the delete alert.
    package var pendingDelete: [String]?
    /// The Add Field or Edit Field sheet.
    package var fieldSheet: FieldDraft?
    /// Selects this row after the next load (the field added, moved or duplicated).
    package private(set) var selectRequest: SelectRequest?
    package var isChanging = false
    /// A rebuild of a big SQLite table waiting on "Rebuild “events”?" (S-070).
    package var pendingRebuild: PendingRebuild?

    package struct PendingRebuild: Identifiable {
        package let id = UUID()
        package let plan: TableChangePlan
        package let rows: Int
        package let select: Int
        package let sheet: FieldDraft?
    }

    /// Tables with more rows than this ask before a rebuild; the self-test lowers it.
    package nonisolated(unsafe) static var rebuildAskRows = 100_000

    // Indexes (S-024, in StructureController+Indexes).
    /// The table's indexes, one entry each, and each Indexes grid row's index name.
    package private(set) var indexSummaries: [IndexSummary] = []
    package private(set) var indexRowNames: [String] = []
    package var indexSelection = IndexSet()
    package var indexGridHasFocus = false
    /// Index names waiting on the delete alert.
    package var pendingIndexDelete: [String]?
    package var indexSheet: IndexDraft?
    /// Selects these Indexes grid rows after the next load (the index added).
    package var indexSelectRequest: SelectRequest?

    package struct SelectRequest: Equatable {
        package let row: Int
        package let id = UUID()
    }

    package struct Target {
        package let client: DatabaseClient
        package let database: String
        package let object: DBObject
        package var key: String { "\(database)/\(object.id)" }
    }

    @ObservationIgnored package private(set) var target: Target?
    @ObservationIgnored private var infos: [FieldInfo] = []
    /// A SQLite table's CREATE TABLE, read into its parts (S-070).
    @ObservationIgnored package private(set) var sqliteTable: SQLiteTable?

    package var isSQLite: Bool { target?.client.dialect.engine == .sqlite }

    /// The table as a change plans against it: name, engine, fields and SQLite's CREATE TABLE.
    package func shape(_ target: Target) -> TableShape {
        TableShape(table: target.object.name, database: target.database, engine: target.client.dialect.engine,
                   fields: definitions, sqlite: sqliteTable)
    }
    /// The grid's columns: SQLite fields have no length, unsigned or comment.
    package private(set) var columns: [Column] = Column.allCases

    package func column(at index: Int) -> Column? { columns.indices.contains(index) ? columns[index] : nil }

    /// Grid columns: the ones edited inline are text; the rest open the Edit Field sheet.
    package enum Column: Int, CaseIterable {
        case name, type, length, unsigned, null, key, defaultValue, extra, collation, comment

        package var title: String {
            switch self {
            case .name: "Name"
            case .type: "Type"
            case .length: "Length"
            case .unsigned: "Unsigned"
            case .null: "Null"
            case .key: "Key"
            case .defaultValue: "Default"
            case .extra: "Extra"
            case .collation: "Collation"
            case .comment: "Comment"
            }
        }

        package var isInline: Bool { [.name, .type, .length, .defaultValue, .comment].contains(self) }
    }

    package func reset() {
        target = nil
        infos = []
        definitions = []
        fields = .empty
        indexes = .empty
        indexSummaries = []
        indexRowNames = []
        sqliteTable = nil
        load = LoadState()
        clearEditState()
    }

    private func clearEditState() {
        editError = nil
        selection = []
        pendingDelete = nil
        fieldSheet = nil
        indexSelection = []
        pendingIndexDelete = nil
        indexSheet = nil
        pendingRebuild = nil
    }

    /// Something else changed the table (a foreign key added its index): load again next time.
    package func invalidate() { load = LoadState() }

    // MARK: Loading

    /// Loads the object's fields (and a table's indexes) unless they are already shown.
    package func show(_ object: DBObject, in database: String, client: DatabaseClient, force: Bool) -> Task<Void, Never>? {
        let next = Target(client: client, database: database, object: object)
        if next.key != target?.key { clearEditState() }
        target = next
        if !force, load.loadedFor == next.key { return nil }
        return Task { await withLoading({ self.load.isLoading = $0 }) { await self.reload(next) } }
    }

    package func reload(_ target: Target) async {
        do {
            let list = try await target.client.fields(of: target.object.name, in: target.database)
            let keys = target.object.kind == .table
                ? try await target.client.indexes(of: target.object.name, in: target.database) : nil
            let sqlite = target.client.dialect.engine == .sqlite
            let create = sqlite && target.object.kind == .table ? try? await target.client.sqliteTable(target.object.name) : nil
            guard self.target?.key == target.key else { return }
            infos = list
            sqliteTable = create
            columns = sqlite ? [.name, .type, .null, .key, .defaultValue, .extra, .collation] : Column.allCases
            definitions = sqlite
                ? list.map { info in FieldDefinition(sqlite: info, column: create?.column(named: info.name).map { create!.columns[$0] }) }
                : list.map(FieldDefinition.init)
            fields = Self.grid(list, columns: columns, sqlite: sqlite)
            indexes = keys.map { GridData($0, picking: GridData.indexColumns) } ?? .empty
            indexRowNames = keys.map { result in result.rows.indices.map { result.string($0, "Key_name") ?? "" } } ?? []
            indexSummaries = keys.map { result in
                IndexSummary.group(names: indexRowNames,
                                   fields: result.rows.indices.map { result.string($0, "Column_name") ?? "" })
            } ?? []
            load = LoadState(loadedFor: target.key)
        } catch {
            guard self.target?.key == target.key else { return }
            load = LoadState(error: DatabaseError.from(error))
        }
    }

    package static func grid(_ fields: [FieldInfo], columns: [Column] = Column.allCases, sqlite: Bool = false) -> GridData {
        let gridColumns = columns.map { GridData.Column(id: "c\($0.rawValue)", title: $0.title) }
        let rows: [[CellValue]] = fields.map { field in
            // A NULL default draws as NULL; no default is empty.
            let defaultCell: CellValue = field.defaultValue.map(CellValue.text) ?? (field.isNullable ? .null : .text(""))
            return columns.map { column -> CellValue in
                switch column {
                case .name: .text(field.name)
                // SQLite's type is as declared, VARCHAR(20) included.
                case .type: .text(sqlite ? field.fullType : field.baseType)
                case .length: .text(field.length)
                case .unsigned: .flag(field.isUnsigned)
                case .null: .flag(field.isNullable)
                case .key: .text(field.key)
                case .defaultValue: defaultCell
                case .extra: .text(sqlite ? field.extra.uppercased() : field.extra)
                case .collation: field.collation.map(CellValue.text) ?? .text("")
                case .comment: .text(field.comment)
                }
            }
        }
        return GridData(columns: gridColumns, rows: rows)
    }

    /// Puts the grid back to what the server sent, after a failed edit.
    private func revert() { fields = Self.grid(infos, columns: columns, sqlite: isSQLite) }

    // MARK: What can change

    /// Fields change only on a loaded table (not a view), one change at a time.
    package var canEdit: Bool {
        guard let target else { return false }
        return target.object.kind == .table && !target.client.isReadOnly && load.loadedFor == target.key && !isChanging
    }

    package var names: [String] { definitions.map(\.name) }

    private var selectedRow: Int? {
        guard selection.count == 1, let row = selection.first, definitions.indices.contains(row) else { return nil }
        return row
    }

    package func canEdit(row: Int, column: Int) -> Bool {
        guard canEdit, definitions.indices.contains(row), let column = self.column(at: column), column.isInline else { return false }
        return !definitions[row].isGenerated
    }

    /// The other columns open the Edit Field sheet on double-click.
    package func opensSheet(row: Int, column: Int) -> Bool {
        guard canEdit, definitions.indices.contains(row), let column = self.column(at: column) else { return false }
        return !column.isInline && !definitions[row].isGenerated
    }

    package func editingText(row: Int, column: Int) -> String {
        guard definitions.indices.contains(row), let column = self.column(at: column) else { return "" }
        let field = definitions[row]
        switch column {
        case .name: return field.name
        case .type: return field.type
        case .length: return field.length
        case .defaultValue: return field.defaultValue.text
        case .comment: return field.comment
        default: return ""
        }
    }

    package var canAddField: Bool { canEdit }
    package var canEditField: Bool { canEdit && selectedRow.map { !definitions[$0].isGenerated } == true }
    package var canDuplicateField: Bool { canEditField }
    package var canDeleteFields: Bool { canEdit && !selection.isEmpty && selection.count < definitions.count }

    package func canMove(by offset: Int) -> Bool {
        guard canEditField, let row = selectedRow else { return false }
        return definitions.indices.contains(row + offset)
    }

    // MARK: Changes

    /// An inline edit: the field with the one value changed, as one ALTER TABLE … CHANGE.
    package func edit(row: Int, column: Int, to value: CellValue) -> Task<Void, Never>? {
        guard canEdit(row: row, column: column), let column = self.column(at: column) else { return nil }
        let old = definitions[row]
        var field = old
        let text = value.plainText ?? ""
        switch column {
        case .name:
            guard !text.isEmpty else {
                editError = DatabaseError(message: "A field needs a name.")
                revert()
                return nil
            }
            field.name = text
        case .type where isSQLite:
            // Any name is a SQLite type: VARCHAR(20), DATETIME, or none.
            field.type = text.trimmingCharacters(in: .whitespaces).lowercased()
            if field.extra == .autoIncrement, field.type != "integer" { field.extra = .none }
        case .defaultValue where isSQLite:
            field.defaultValue = value.isNull ? .null : SQLiteTableChange.typedDefault(text)
        case .type:
            let parsed = FieldInfo.parseType(text.trimmingCharacters(in: .whitespaces))
            guard !parsed.base.isEmpty else { revert(); return nil }
            field = field.changingType(to: parsed.base)
            if !parsed.length.isEmpty { field.length = parsed.length }
            if parsed.unsigned { field.isUnsigned = true }
            if parsed.zerofill { field.isZerofill = true }
        case .length:
            field.length = text.trimmingCharacters(in: .whitespaces)
        case .defaultValue:
            field.defaultValue = value.isNull || text == "NULL" ? .null : FieldDefault(typed: text)
        case .comment:
            field.comment = text
        default:
            return nil
        }
        guard field != old else { return nil }
        return perform(.editField(old.name, field, .unchanged), select: row)
    }

    /// Add Field…: the sheet, placed after the selected field (or at the end).
    package func requestAddField() {
        guard canAddField, let target else { return }
        let after = selection.max().map { names[$0] } ?? names.last
        let field = FieldDefinition(name: "", type: isSQLite ? "text" : "int", isNullable: true, defaultValue: .null)
        fieldSheet = FieldDraft(shape: shape(target), field: field, original: nil, names: names,
                                position: after.map(FieldPosition.after) ?? .first)
        if !isSQLite { loadCatalog(target) }
    }

    /// Edit Field…: the selected field (or `row`) in the sheet.
    package func requestEditField(row: Int? = nil) {
        guard let target, let row = row ?? selectedRow, canEdit, definitions.indices.contains(row),
              !definitions[row].isGenerated else { return }
        let position: FieldPosition = row == 0 ? .first : .after(names[row - 1])
        fieldSheet = FieldDraft(shape: shape(target), field: definitions[row], original: definitions[row].name,
                                names: names, position: position)
        if !isSQLite { loadCatalog(target) }
    }

    private func loadCatalog(_ target: Target) {
        let sheet = fieldSheet
        Task {
            let catalog = try? await target.client.charsetCatalog()
            sheet?.catalog = catalog
        }
    }

    /// Add or Save in the sheet: the add, or the edit with its new position. The sheet stays open on an error.
    package func saveSheet() -> Task<Void, Never>? {
        guard let sheet = fieldSheet, sheet.canSave else { return nil }
        let field = sheet.definition
        let landing: Int
        if let original = sheet.original {
            var order = names.filter { $0 != original }
            let at = sheet.position == sheet.originalPosition ? names.firstIndex(of: original) ?? 0
                : Self.index(of: sheet.position, in: order, fallback: 0)
            order.insert(field.name, at: min(at, order.count))
            landing = order.firstIndex(of: field.name) ?? 0
        } else {
            landing = Self.index(of: sheet.position, in: names, fallback: names.count)
        }
        return perform(sheet.change, select: landing, sheet: sheet)
    }

    /// Where a field lands among `names` (which doesn't hold it).
    private static func index(of position: FieldPosition, in names: [String], fallback: Int) -> Int {
        switch position {
        case .unchanged: min(fallback, names.count)
        case .first: 0
        case .after(let name): (names.firstIndex(of: name) ?? names.count - 1) + 1
        }
    }

    /// Duplicate Field: a copy named "_copy" right after it.
    package func duplicateField() -> Task<Void, Never>? {
        guard canDuplicateField, let row = selectedRow else { return nil }
        return perform(.duplicateField(names[row]), select: row + 1)
    }

    package func requestDeleteFields() {
        guard canDeleteFields else { return }
        pendingDelete = selection.sorted().filter(definitions.indices.contains).map { names[$0] }
    }

    package func confirmDeleteFields() -> Task<Void, Never>? {
        guard let doomed = pendingDelete, !doomed.isEmpty else { return nil }
        pendingDelete = nil
        let first = selection.min() ?? 0
        return perform(.dropFields(doomed), select: max(0, min(first, definitions.count - doomed.count - 1)))
    }

    /// Dragging a field: the field edited in place with FIRST or AFTER.
    package func move(from source: Int, to destination: Int) -> Task<Void, Never>? {
        guard canEdit, definitions.indices.contains(source), !definitions[source].isGenerated,
              let place = FieldChange.dropPosition(moving: source, to: destination, in: names) else { return nil }
        let field = definitions[source]
        return perform(.editField(field.name, field, place), select: destination > source ? destination - 1 : destination)
    }

    /// Move Field Up (⌃⌘↑) and Move Field Down (⌃⌘↓).
    package func moveSelected(by offset: Int) -> Task<Void, Never>? {
        guard canMove(by: offset), let row = selectedRow else { return nil }
        return move(from: row, to: offset < 0 ? row - 1 : row + 2)
    }

    package func canDrag(row: Int) -> Bool { canEdit && definitions.indices.contains(row) && !definitions[row].isGenerated }

    // MARK: Running a change

    /// Plans the change and runs it, then reloads and selects `row`. A SQLite rebuild of a table
    /// over `rebuildAskRows` rows asks first (S-070). On an error the sheet shows it, or the grid
    /// goes back and the message shows above the status bar.
    package func perform(_ change: TableChange, select row: Int, sheet: FieldDraft? = nil) -> Task<Void, Never>? {
        guard let target else { return nil }
        let plan: TableChangePlan
        do {
            plan = try change.plan(shape(target))
        } catch {
            fail(DatabaseError.from(error), sheet: sheet)
            return nil
        }
        guard !plan.isEmpty else {
            if let sheet, fieldSheet === sheet { fieldSheet = nil }
            return nil
        }
        editError = nil
        isChanging = true
        sheet?.isSaving = true
        sheet?.error = nil
        return Task {
            if plan.needsRebuild, let rows = try? await target.client.rowCount(of: target.object.name, in: target.database),
               rows > Self.rebuildAskRows {
                isChanging = false
                sheet?.isSaving = false
                pendingRebuild = PendingRebuild(plan: plan, rows: rows, select: row, sheet: sheet)
                return
            }
            await apply(plan, target: target, select: row, sheet: sheet)
        }
    }

    /// Rebuild in the alert.
    package func confirmRebuild() -> Task<Void, Never>? {
        guard let pending = pendingRebuild, let target else { return nil }
        pendingRebuild = nil
        isChanging = true
        pending.sheet?.isSaving = true
        return Task { await apply(pending.plan, target: target, select: pending.select, sheet: pending.sheet) }
    }

    package func cancelRebuild() {
        pendingRebuild = nil
        revert()
    }

    private func apply(_ plan: TableChangePlan, target: Target, select row: Int, sheet: FieldDraft?) async {
        defer {
            isChanging = false
            sheet?.isSaving = false
        }
        do {
            try await target.client.apply(plan)
            if let sheet, fieldSheet === sheet { fieldSheet = nil }
            await finish(target, select: row)
        } catch {
            guard self.target?.key == target.key else { return }
            fail(DatabaseError.from(error), sheet: sheet)
        }
    }

    private func fail(_ error: DatabaseError, sheet: FieldDraft?) {
        if let sheet, fieldSheet === sheet {
            sheet.error = error
        } else {
            editError = error
            revert()
        }
    }

    /// "Rebuild “events”?" and what it does.
    package static func rebuildTitle(_ table: String) -> String { "Rebuild \u{201C}\(table)\u{201D}?" }

    package static func rebuildMessage(rows: Int, noun: String = "field") -> String {
        "SQLite changes this \(noun) by copying the table\u{2019}s \(rows.formatted()) rows into a new one. Nothing changes if it fails."
    }

    package func finish(_ target: Target, select row: Int) async {
        await reload(target)
        guard self.target?.key == target.key, definitions.indices.contains(row) else { return }
        selection = [row]
        selectRequest = SelectRequest(row: row)
    }
}
