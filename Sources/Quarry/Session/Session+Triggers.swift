import Foundation
import QuarryKit

/// Triggers' commands (S-026), run by `TriggersController`.
extension Session {
    func requestAddTrigger() {
        view = .triggers
        if let task = triggers.requestSheet(editing: nil) { currentLoad = task }
    }

    /// Edit Trigger…: the row given (double-click, row menu) or the one selected.
    func requestEditTrigger(row: Int? = nil) {
        guard let row = row ?? (triggers.selection.count == 1 ? triggers.selection.first : nil) else { return }
        if let task = triggers.requestSheet(editing: row) { currentLoad = task }
    }

    func saveTriggerSheet() { if let task = triggers.saveSheet() { currentLoad = task } }

    func requestDeleteTriggers() { triggers.requestDelete() }

    func confirmDeleteTriggers() { if let task = triggers.confirmDelete() { currentLoad = task } }
}
