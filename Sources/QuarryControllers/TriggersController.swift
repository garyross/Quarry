import Foundation
import Observation
import QuarryKit

/// Triggers (⌘4): a table's triggers, adding and editing one in a sheet and
/// deleting the selected ones (S-026). The server has no ALTER TRIGGER, so an
/// edit drops the trigger and creates it again, and puts the original back on error.
@Observable
package final class TriggersController {
    package init() {}

    package private(set) var grid = GridData.empty
    package private(set) var load = LoadState()
    package private(set) var triggers: [TriggerDefinition] = []
    package var selection = IndexSet()
    package var gridHasFocus = false
    /// Trigger names waiting on the delete alert.
    package var pendingDelete: [String]?
    package var sheet: TriggerDraft?
    /// Why a delete failed (or the sheet couldn't open), above the status bar.
    package var editError: DatabaseError?
    package var isChanging = false
    /// Selects this row after the next load (the trigger added or saved).
    package private(set) var selectRequest: StructureController.SelectRequest?

    package struct Target {
        package let client: DatabaseClient
        package let database: String
        package let object: DBObject
        package var key: String { "\(database)/\(object.id)" }
    }

    @ObservationIgnored package private(set) var target: Target?

    package func reset() {
        target = nil
        grid = .empty
        triggers = []
        load = LoadState()
        clearEditState()
    }

    private func clearEditState() {
        selection = []
        pendingDelete = nil
        sheet = nil
        editError = nil
    }

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
            let result = try await target.client.triggers(of: target.object.name, in: target.database)
            guard self.target?.key == target.key else { return }
            triggers = TriggerDefinition.list(from: result)
            grid = GridData(result, picking: GridData.triggerColumns)
            load = LoadState(loadedFor: target.key)
        } catch {
            guard self.target?.key == target.key else { return }
            load = LoadState(error: DatabaseError.from(error))
        }
    }

    // MARK: What can change

    package var canChange: Bool {
        guard let target else { return false }
        return target.object.kind == .table && !target.client.isReadOnly && load.loadedFor == target.key
            && !isChanging && sheet == nil
    }

    package var canAdd: Bool { canChange }

    package var selectedNames: [String] {
        selection.sorted().filter(triggers.indices.contains).map { triggers[$0].name }
    }

    package var canEdit: Bool { canChange && selectedNames.count == 1 }

    package var canDelete: Bool { canChange && !selectedNames.isEmpty }

    // MARK: Add and edit

    /// Add Trigger… (nil) or Edit Trigger… (a row): loads the database's trigger names, then opens the sheet.
    package func requestSheet(editing row: Int?) -> Task<Void, Never>? {
        guard canChange, let target else { return nil }
        let original = row.flatMap { triggers.indices.contains($0) ? triggers[$0] : nil }
        if row != nil, original == nil { return nil }
        isChanging = true
        editError = nil
        return Task {
            defer { isChanging = false }
            do {
                let taken = try await target.client.triggerNames(in: target.database)
                guard self.target?.key == target.key else { return }
                let draft = TriggerDraft(table: target.object.name, original: original, taken: taken)
                draft.isSQLite = target.client.dialect.engine == .sqlite
                sheet = draft
            } catch {
                editError = DatabaseError.from(error)
            }
        }
    }

    /// Add or Save in the sheet. The sheet stays open, filled in, on an error.
    package func saveSheet() -> Task<Void, Never>? {
        guard let draft = sheet, draft.canSave, let target else { return nil }
        let trigger = draft.definition
        let plan = TriggerChange.plan(trigger, replacing: draft.original, on: target.object.name, in: target.database,
                                      engine: target.client.dialect.engine)
        draft.isSaving = true
        draft.error = nil
        isChanging = true
        return Task {
            defer {
                draft.isSaving = false
                isChanging = false
            }
            do {
                try await Self.apply(plan, client: target.client)
                if sheet === draft { sheet = nil }
                await reload(target)
                if let row = triggers.firstIndex(where: { $0.name.caseInsensitiveCompare(trigger.name) == .orderedSame }) {
                    selection = [row]
                    selectRequest = .init(row: row)
                }
            } catch {
                draft.error = DatabaseError.from(error)
                await reload(target)
            }
        }
    }

    /// Drop, create, and on a failed create the original again. A failed drop changes nothing.
    package static func apply(_ plan: TriggerChange.Plan, client: DatabaseClient) async throws {
        if let drop = plan.drop { _ = try await client.run(drop) }
        do {
            _ = try await client.run(plan.create)
        } catch {
            guard let restore = plan.restore else { throw error }
            var failure = DatabaseError.from(error)
            do {
                _ = try await client.run(restore)
                failure.suggestion = "The trigger wasn\u{2019}t changed."
            } catch {
                failure.suggestion = "The original trigger couldn\u{2019}t be put back: "
                    + DatabaseError.from(error).message
            }
            throw failure
        }
    }

    // MARK: Delete

    package func requestDelete() {
        guard canDelete else { return }
        pendingDelete = selectedNames
    }

    package func confirmDelete() -> Task<Void, Never>? {
        guard let doomed = pendingDelete, !doomed.isEmpty, let target else { return nil }
        pendingDelete = nil
        editError = nil
        isChanging = true
        return Task {
            defer { isChanging = false }
            do {
                for name in doomed { _ = try await target.client.run(TriggerChange.dropSQL(name, in: target.database)) }
                await reload(target)
                selection = []
            } catch {
                guard self.target?.key == target.key else { return }
                editError = DatabaseError.from(error)
                await reload(target)
            }
        }
    }

    package static func deleteTitle(_ names: [String]) -> String {
        names.count == 1 ? "Delete the trigger \u{201C}\(names[0])\u{201D}?" : "Delete \(names.count) triggers?"
    }

    package static func deleteMenuTitle(_ count: Int) -> String {
        count > 1 ? "Delete \(count) Triggers…" : "Delete Trigger…"
    }
}
