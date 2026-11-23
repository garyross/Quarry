import Foundation
import Observation
import QuarryKit

/// Foreign Keys (⌘3): a table's foreign keys, adding one with a sheet and
/// deleting the selected ones (S-025). Each change is a `TableChange` run through
/// `perform`: one ALTER TABLE on MySQL, a table rebuild on SQLite (S-070).
@Observable
package final class ForeignKeysController {
    package init() {}

    package private(set) var grid = GridData.empty
    package private(set) var load = LoadState()
    package private(set) var keys: [ForeignKeyInfo] = []
    /// The table's engine; foreign keys need InnoDB.
    package private(set) var engine: String?
    package var selection = IndexSet()
    package var gridHasFocus = false
    /// Key names waiting on the delete alert.
    package var pendingDelete: [String]?
    package var sheet: ForeignKeyDraft?
    /// Why a delete failed (or the sheet couldn't open), above the status bar.
    package var editError: DatabaseError?
    package var isChanging = false
    /// Selects this row after the next load (the key added).
    package private(set) var selectRequest: StructureController.SelectRequest?

    package struct Target {
        package let client: DatabaseClient
        package let database: String
        package let object: DBObject
        package var key: String { "\(database)/\(object.id)" }
    }

    @ObservationIgnored package private(set) var target: Target?
    @ObservationIgnored private var engines: [String: String] = [:]

    package func reset() {
        target = nil
        grid = .empty
        keys = []
        engine = nil
        engines = [:]
        load = LoadState()
        clearEditState()
    }

    private func clearEditState() {
        selection = []
        pendingDelete = nil
        sheet = nil
        editError = nil
    }

    /// Something else changed the table (a field or index): load again next time.
    package func invalidate() { load = LoadState() }

    // MARK: Loading

    package func show(_ object: DBObject, in database: String, client: DatabaseClient, force: Bool) -> Task<Void, Never>? {
        let next = Target(client: client, database: database, object: object)
        if next.key != target?.key { clearEditState() }
        target = next
        if !force, load.loadedFor == next.key { return nil }
        return Task { await withLoading({ self.load.isLoading = $0 }) { await self.reload(next) } }
    }

    package func reload(_ target: Target) async {
        do {
            let list = try await target.client.foreignKeys(of: target.object.name, in: target.database)
            var engines = try await target.client.tableEngines(in: target.database)
            if target.client.dialect.engine == .sqlite {
                // Every SQLite table has foreign keys (S-070).
                for table in try await target.client.tablesAndViews(in: target.database) where table.kind == .table {
                    engines[table.name] = "InnoDB"
                }
            }
            guard self.target?.key == target.key else { return }
            keys = list
            self.engines = engines
            engine = engines[target.object.name]
            grid = GridData.foreignKeys(list, database: target.database)
            load = LoadState(loadedFor: target.key)
        } catch {
            guard self.target?.key == target.key else { return }
            load = LoadState(error: DatabaseError.from(error))
        }
    }

    // MARK: What can change

    package var supportsKeys: Bool { isSQLite || engine?.caseInsensitiveCompare("InnoDB") == .orderedSame }

    package var isSQLite: Bool { target?.client.dialect.engine == .sqlite }

    package var canEdit: Bool {
        guard let target else { return false }
        return target.object.kind == .table && load.loadedFor == target.key && supportsKeys && !isChanging
    }

    package var canAdd: Bool { canEdit && sheet == nil }

    package var selectedNames: [String] {
        selection.sorted().filter(keys.indices.contains).map { keys[$0].name }
    }

    package var canDelete: Bool { canEdit && !selectedNames.isEmpty }

    /// "“notes” uses MyISAM. Change its engine to InnoDB to add foreign keys."
    package var engineNote: String? {
        guard let target, load.loadedFor == target.key, !supportsKeys else { return nil }
        return "\u{201C}\(target.object.name)\u{201D} uses \(engine ?? "another engine"). "
            + "Change its engine to InnoDB to add foreign keys."
    }

    // MARK: Add

    /// Add Foreign Key…: loads the table's fields, then opens the sheet and loads the referenced table.
    package func requestAdd() -> Task<Void, Never>? {
        guard canAdd, let target else { return nil }
        isChanging = true
        editError = nil
        return Task {
            defer { isChanging = false }
            do {
                let fields = try await target.client.fields(of: target.object.name, in: target.database)
                let shape = try await target.client.tableShape(target.object.name, in: target.database,
                                                               foreignKeys: keys.map(\.name))
                guard self.target?.key == target.key else { return }
                let tables = engines.filter { $0.value.caseInsensitiveCompare("InnoDB") == .orderedSame }.keys
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                let keyed = Set(keys.flatMap { $0.columns.components(separatedBy: ", ") })
                let sqlite = isSQLite
                let draft = ForeignKeyDraft(shape: shape,
                                            fields: fields.map { sqlite ? FieldDefinition(sqlite: $0, column: nil) : FieldDefinition($0) },
                                            keyed: keyed, tables: tables, existing: keys.map(\.name))
                sheet = draft
                await loadReference(for: draft)
            } catch {
                editError = DatabaseError.from(error)
            }
        }
    }

    /// The References menu changed: load that table's fields and indexes once.
    @discardableResult
    package func referencedTableChanged() -> Task<Void, Never>? {
        guard let draft = sheet else { return nil }
        draft.referencedTableChanged()
        return Task { await loadReference(for: draft) }
    }

    private func loadReference(for draft: ForeignKeyDraft) async {
        let table = draft.referencedTable
        guard let target, !table.isEmpty, draft.catalog[table] == nil else { return }
        do {
            let fields = try await target.client.fields(of: table, in: target.database)
            let result = try await target.client.indexes(of: table, in: target.database)
            let names = result.rows.indices.map { result.string($0, "Key_name") ?? "" }
            let columns = result.rows.indices.map { result.string($0, "Column_name") ?? "" }
            let unique = Set(result.rows.indices.filter { result.string($0, "Non_unique") == "0" }.map { names[$0] })
            let sqlite = draft.isSQLite
            draft.store(.init(fields: fields.map { sqlite ? FieldDefinition(sqlite: $0, column: nil) : FieldDefinition($0) },
                              indexes: IndexSummary.group(names: names, fields: columns), unique: unique), for: table)
        } catch {
            draft.error = DatabaseError.from(error)
        }
    }

    /// Add in the sheet. The sheet stays open, filled in, on an error.
    package func saveSheet() -> Task<Void, Never>? {
        guard let draft = sheet, draft.canSave else { return nil }
        return perform(draft.change, sheet: draft)
    }

    // MARK: Delete

    package func requestDelete() {
        guard canDelete else { return }
        pendingDelete = selectedNames
    }

    package func confirmDelete() -> Task<Void, Never>? {
        guard let doomed = pendingDelete, !doomed.isEmpty else { return nil }
        pendingDelete = nil
        return perform(.dropForeignKeys(doomed), sheet: nil)
    }

    // MARK: Running a change

    /// A rebuild of a big SQLite table waiting on "Rebuild “orders”?" (S-070).
    package var pendingRebuild: StructureController.PendingRebuild?
    @ObservationIgnored private var pendingSheet: ForeignKeyDraft?

    /// Plans the change against the table as it is now and runs it; a SQLite rebuild of a big
    /// table asks first. An error shows in the sheet, or above the status bar.
    private func perform(_ change: TableChange, sheet draft: ForeignKeyDraft?) -> Task<Void, Never>? {
        guard let target else { return nil }
        let names = keys.map(\.name)
        editError = nil
        isChanging = true
        draft?.isSaving = true
        draft?.error = nil
        return Task {
            defer {
                isChanging = false
                draft?.isSaving = false
            }
            do {
                let shape = try await target.client.tableShape(target.object.name, in: target.database, foreignKeys: names)
                let plan = try change.plan(shape)
                if plan.needsRebuild {
                    let rows = try await target.client.rowCount(of: target.object.name, in: target.database)
                    if rows > StructureController.rebuildAskRows {
                        pendingSheet = draft
                        pendingRebuild = .init(plan: plan, rows: rows, select: 0, sheet: nil)
                        return
                    }
                }
                try await apply(plan, target: target, sheet: draft)
            } catch {
                await report(error, target: target, sheet: draft)
            }
        }
    }

    package func confirmRebuild() -> Task<Void, Never>? {
        guard let pending = pendingRebuild, let target else { return nil }
        pendingRebuild = nil
        let draft = pendingSheet
        pendingSheet = nil
        isChanging = true
        draft?.isSaving = true
        return Task {
            defer {
                isChanging = false
                draft?.isSaving = false
            }
            do {
                try await apply(pending.plan, target: target, sheet: draft)
            } catch {
                await report(error, target: target, sheet: draft)
            }
        }
    }

    package func cancelRebuild() {
        pendingRebuild = nil
        pendingSheet = nil
    }

    /// Runs the plan, reloads, and selects the key a sheet added: the one with new fields and
    /// reference, or (two keys alike on MySQL) the new name.
    private func apply(_ plan: TableChangePlan, target: Target, sheet draft: ForeignKeyDraft?) async throws {
        func signature(_ key: ForeignKeyInfo) -> String { "\(key.columns)>\(key.referencedTable).\(key.referencedColumns)" }
        let before = Set(keys.map(signature))
        let names = Set(keys.map(\.name))
        try await target.client.apply(plan)
        if let draft, sheet === draft { sheet = nil }
        await reload(target)
        selection = []
        guard draft != nil,
              let row = keys.firstIndex(where: { !before.contains(signature($0)) }) ?? keys.firstIndex(where: { !names.contains($0.name) })
        else { return }
        selection = [row]
        selectRequest = .init(row: row)
    }

    private func report(_ error: any Error, target: Target, sheet draft: ForeignKeyDraft?) async {
        guard self.target?.key == target.key else { return }
        var error = DatabaseError.from(error)
        // 1005, 1215, 1822: InnoDB refused the key; its status says why (nil on SQLite).
        if [1005, 1215, 1822].contains(error.code ?? 0), let detail = await target.client.latestForeignKeyError() {
            error.suggestion = detail
        }
        if let draft, sheet === draft { draft.error = error } else { editError = error }
    }

    package static func deleteTitle(_ names: [String]) -> String {
        names.count == 1 ? "Delete the foreign key \u{201C}\(names[0])\u{201D}?" : "Delete \(names.count) foreign keys?"
    }

    package static func deleteMenuTitle(_ count: Int) -> String {
        count > 1 ? "Delete \(count) Foreign Keys…" : "Delete Foreign Key…"
    }
}
