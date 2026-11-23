import Foundation
import Observation
import QuarryKit

/// The Add Trigger and Edit Trigger sheet's state (S-026): a name, when it
/// runs, and its statement. Saving an edit drops the trigger and creates it
/// again; the original comes back when the create fails.
@Observable
package final class TriggerDraft: Identifiable {
    package let id = UUID()
    package let table: String
    /// The trigger being edited; nil adds one.
    package let original: TriggerDefinition?
    /// Every trigger name in the database, for the name check.
    package let taken: [String]

    package var name: String
    package var timing: TriggerTiming {
        didSet { renameIfSuggested(oldTiming: oldValue, oldEvent: event) }
    }
    package var event: TriggerEvent {
        didSet { renameIfSuggested(oldTiming: timing, oldEvent: oldValue) }
    }
    package var statement: String
    package var error: DatabaseError?
    package var isSaving = false

    /// A SQLite table (S-070): the header has no FOR EACH ROW, and UPDATE OF's fields stay as they were.
    package var isSQLite = false

    package init(table: String, original: TriggerDefinition?, taken: [String]) {
        self.table = table
        self.original = original
        self.taken = taken
        let timing = original?.timing ?? .before
        let event = original?.event ?? .insert
        self.timing = timing
        self.event = event
        statement = original?.statement ?? ""
        name = original?.name ?? TriggerChange.suggestedName(table: table, timing: timing, event: event, taken: taken)
    }

    package var isEdit: Bool { original != nil }

    package var title: String {
        if let original { return "Edit Trigger \u{201C}\(original.name)\u{201D}" }
        return "Add Trigger to \u{201C}\(table)\u{201D}"
    }

    package var saveTitle: String { isEdit ? "Save" : "Add" }

    package var definition: TriggerDefinition {
        TriggerDefinition(name: name.trimmingCharacters(in: .whitespaces), timing: timing, event: event, statement: statement,
                          columns: event == .update ? original?.columns ?? "" : "")
    }

    package var nameProblem: String? { TriggerChange.nameProblem(name, taken: taken, original: original?.name) }

    package var isChanged: Bool { original.map { $0 != definition } ?? true }

    package var canSave: Bool {
        !definition.name.isEmpty && nameProblem == nil && !definition.trimmedStatement.isEmpty && isChanged && !isSaving
    }

    /// The fixed start of the statement, shown above the editor.
    package var header: String {
        if isSQLite {
            let columns = definition.columns.isEmpty ? "" : " OF " + definition.columns
            return "CREATE TRIGGER " + SQLiteTable.quote(definition.name.isEmpty ? "…" : definition.name) + " "
                + timing.rawValue + " " + event.rawValue + columns + " ON " + SQLiteTable.quote(table)
        }
        return "CREATE TRIGGER " + SQLQuote.identifier(definition.name.isEmpty ? "…" : definition.name) + " "
            + timing.rawValue + " " + event.rawValue + " ON " + SQLQuote.identifier(table) + " FOR EACH ROW"
    }

    /// A new trigger's name follows Action Time and Event until people type their own.
    private func renameIfSuggested(oldTiming: TriggerTiming, oldEvent: TriggerEvent) {
        guard original == nil,
              name == TriggerChange.suggestedName(table: table, timing: oldTiming, event: oldEvent, taken: taken)
        else { return }
        name = TriggerChange.suggestedName(table: table, timing: timing, event: event, taken: taken)
    }
}
