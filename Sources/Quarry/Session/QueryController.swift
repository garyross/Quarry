import Foundation
import Observation
import QuarryKit
import QuarryControllers

/// Query (⌘6): the editor's text and caret, the results, and the run bar's
/// state. A class, so each property is observed on its own: the editor writes
/// `text`, `cursor` and `selection` on every keystroke and caret move, and
/// only the views that read them update (docs/architecture-review-2026-11-19.md).
/// The statements themselves run in `Session+Query`.
@Observable
final class QueryController {
    var text = "" {
        didSet {
            let new = text.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
            if new != hasText { hasText = new }
        }
    }
    /// The editor holds more than white space: Save Query… (S-034). Set only
    /// when it flips, so the menus don't update on every keystroke.
    private(set) var hasText = false
    /// UTF-16 offset of the cursor in the editor.
    var cursor = 0
    var results = GridData.empty
    /// The table Copy as SQL INSERT names for these results (S-016).
    var resultTable = "<table>"
    /// The server's columns and the statement behind the results, for Export (S-042).
    var resultColumns: [ResultColumn] = []
    var resultStatement = ""
    /// "1,204 rows · 0.031 s", or what Run All did.
    var status = ""
    var error: DatabaseError?
    /// The error's line in the editor (1-based), when the server named one.
    var errorLine: Int?
    var isRunning = false
    /// Cancel was pressed: KILL QUERY is on its way, and no further statement starts (S-036).
    var isCancelling = false
    /// The editor moves its cursor here and clears it (clicking the error bar).
    var selectRequest: NSRange?
    /// Show Completions (⌥⎋): the editor opens its list and clears this (S-031).
    var completionRequest = false
    /// A Query menu editing command (S-032): the editor runs it and clears this.
    var editorCommand: EditorCommand?
    /// Bumped when the completion catalog gains a database, so an open list refreshes.
    var completionRevision = 0
    /// Text the editor puts in place of the selection, then selects, and clears this (S-033).
    var insertRequest: String?
    /// Previous and Next Query from History: where in the history the last step landed.
    var historyStepper = HistoryStepper()
    /// Set while a history step changes the text, so that change keeps the stepper's place.
    var isInsertingHistory = false
    /// The History popover in the run bar (⌃⌘H).
    var showsHistory = false
    /// The editor's selection, as UTF-16 offsets (S-034).
    var selection = NSRange(location: 0, length: 0)
    /// The Undo name of the next `insertRequest`.
    var insertActionName = "Insert Query from History"
    /// The Saved Queries popover in the run bar (S-034).
    var showsSavedQueries = false
    /// Which result cells can be edited, and how (S-035).
    var editing = ResultEditing.none
    /// Each result column's field in its table, when it is editable: its type and NULL rule.
    var resultFields: [FieldInfo?] = []
    /// A failed cell edit in the results.
    var editError: DatabaseError?

    /// Back to an empty editor with no results, as after disconnecting.
    func reset() {
        text = ""
        cursor = 0
        results = .empty
        resultTable = "<table>"
        resultColumns = []
        resultStatement = ""
        status = ""
        error = nil
        errorLine = nil
        isRunning = false
        isCancelling = false
        selectRequest = nil
        completionRequest = false
        editorCommand = nil
        completionRevision = 0
        insertRequest = nil
        historyStepper = HistoryStepper()
        isInsertingHistory = false
        showsHistory = false
        selection = NSRange(location: 0, length: 0)
        insertActionName = "Insert Query from History"
        showsSavedQueries = false
        editing = .none
        resultFields = []
        editError = nil
    }
}
