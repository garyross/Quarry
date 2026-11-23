import Foundation
import QuarryKit

/// Structure's indexes (S-024): Add Index… opens a sheet whose `TableChange`
/// adds one; Delete Index… drops the selected ones (one ALTER TABLE on MySQL,
/// a DROP INDEX each on SQLite).
extension StructureController {
    /// The indexes behind the selected Indexes grid rows, in grid order, each once.
    package var selectedIndexNames: [String] {
        var names: [String] = []
        for row in indexSelection.sorted() where indexRowNames.indices.contains(row) {
            if !names.contains(indexRowNames[row]) { names.append(indexRowNames[row]) }
        }
        return names
    }

    package var canAddIndex: Bool { canEdit && !definitions.isEmpty }
    package var canDeleteIndexes: Bool {
        canEdit && !selectedIndexNames.isEmpty && (!isSQLite || selectedIndexNames.allSatisfy(IndexChange.sqliteCanDrop))
    }

    /// Add Index…: the sheet, holding the fields selected in the fields grid.
    package func requestAddIndex() {
        guard canAddIndex, let target else { return }
        let selected = selection.sorted().filter(definitions.indices.contains).map { names[$0] }
        indexSheet = IndexDraft(shape: shape(target), indexes: indexSummaries, selected: selected)
    }

    /// Add in the sheet. The sheet stays open, filled in, on an error.
    package func saveIndexSheet() -> Task<Void, Never>? {
        guard let sheet = indexSheet, sheet.canSave, let target else { return nil }
        let shape = shape(target)
        sheet.isSaving = true
        sheet.error = nil
        isChanging = true
        return Task {
            defer {
                sheet.isSaving = false
                isChanging = false
            }
            do {
                try await target.client.apply(sheet.change.plan(shape))
                if indexSheet === sheet { indexSheet = nil }
                await reload(target)
                selectIndex(named: sheet.landingName)
            } catch {
                sheet.error = DatabaseError.from(error)
            }
        }
    }

    private func selectIndex(named name: String) {
        guard let row = indexRowNames.firstIndex(of: name) else { return }
        indexSelection = [row]
        indexSelectRequest = SelectRequest(row: row)
    }

    package func requestDeleteIndexes() {
        guard canDeleteIndexes else { return }
        pendingIndexDelete = selectedIndexNames
    }

    package func confirmDeleteIndexes() -> Task<Void, Never>? {
        guard let doomed = pendingIndexDelete, !doomed.isEmpty, let target else { return nil }
        pendingIndexDelete = nil
        editError = nil
        isChanging = true
        let shape = shape(target)
        return Task {
            defer { isChanging = false }
            do {
                try await target.client.apply(TableChange.dropIndexes(doomed).plan(shape))
                await reload(target)
                indexSelection = []
            } catch {
                guard self.target?.key == target.key else { return }
                var error = DatabaseError.from(error)
                // ER_DROP_INDEX_FK: a foreign key needs the index.
                if error.code == 1553 {
                    error.suggestion = "A foreign key uses this index. Delete the foreign key first, in Foreign Keys (⌘3)."
                }
                editError = error
            }
        }
    }

    package static func deleteIndexTitle(_ names: [String]) -> String {
        guard names.count == 1 else { return "Delete \(names.count) indexes?" }
        return names[0] == "PRIMARY" ? "Delete the primary key?" : "Delete the index \u{201C}\(names[0])\u{201D}?"
    }
}
