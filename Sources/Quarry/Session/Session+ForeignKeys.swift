import Foundation
import QuarryKit

/// Foreign Keys' commands (S-025). Each runs one ALTER TABLE in
/// `ForeignKeysController`; afterwards Structure, Content and Info load again when shown.
extension Session {
    func requestAddForeignKey() {
        view = .foreignKeys
        if let task = foreignKeys.requestAdd() { currentLoad = task }
    }

    func foreignKeyTableChanged() {
        if let task = foreignKeys.referencedTableChanged() { currentLoad = task }
    }

    func saveForeignKeySheet() { afterForeignKeyChange(foreignKeys.saveSheet()) }

    func requestDeleteForeignKeys() { foreignKeys.requestDelete() }

    func confirmDeleteForeignKeys() { afterForeignKeyChange(foreignKeys.confirmDelete()) }

    /// Rebuild in "Rebuild “orders”?" (S-070).
    func confirmForeignKeyRebuild() { afterForeignKeyChange(foreignKeys.confirmRebuild()) }

    /// The self-test awaits `currentLoad`.
    private func afterForeignKeyChange(_ task: Task<Void, Never>?) {
        guard let task else { return }
        currentLoad = Task {
            await task.value
            structure.invalidate()
            content.invalidate()
            info.invalidate()
        }
    }
}
