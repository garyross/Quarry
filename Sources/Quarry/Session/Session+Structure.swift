import Foundation
import QuarryKit

/// Structure's field commands (S-023). Each runs one ALTER TABLE in
/// `StructureController`; afterwards Content and Info load again when shown.
extension Session {
    func editField(row: Int, column: Int, to value: CellValue) {
        afterFieldChange(structure.edit(row: row, column: column, to: value))
    }

    func requestAddField() {
        view = .structure
        structure.requestAddField()
    }

    func requestEditField(row: Int? = nil) { structure.requestEditField(row: row) }

    func saveFieldSheet() { afterFieldChange(structure.saveSheet()) }

    func duplicateField() { afterFieldChange(structure.duplicateField()) }

    func requestDeleteFields() { structure.requestDeleteFields() }

    func confirmDeleteFields() { afterFieldChange(structure.confirmDeleteFields()) }

    /// Rebuild in "Rebuild “events”?" (S-070).
    func confirmRebuild() { afterFieldChange(structure.confirmRebuild()) }

    func moveField(from source: Int, to destination: Int) {
        afterFieldChange(structure.move(from: source, to: destination))
    }

    /// Move Field Up (⌃⌘↑) and Move Field Down (⌃⌘↓).
    func moveField(by offset: Int) { afterFieldChange(structure.moveSelected(by: offset)) }

    // MARK: Indexes (S-024)

    func requestAddIndex() {
        view = .structure
        structure.requestAddIndex()
    }

    func saveIndexSheet() { afterFieldChange(structure.saveIndexSheet()) }

    func requestDeleteIndexes() { structure.requestDeleteIndexes() }

    func confirmDeleteIndexes() { afterFieldChange(structure.confirmDeleteIndexes()) }

    /// The self-test awaits `currentLoad`.
    private func afterFieldChange(_ task: Task<Void, Never>?) {
        guard let task else { return }
        currentLoad = Task {
            await task.value
            content.invalidate()
            foreignKeys.invalidate()
            info.invalidate()
        }
    }
}

extension Session {
    /// Table > Delete Index… / Delete 2 Indexes… (S-024).
    static func deleteIndexMenuTitle(_ count: Int) -> String {
        count > 1 ? "Delete \(count) Indexes…" : "Delete Index…"
    }
}
