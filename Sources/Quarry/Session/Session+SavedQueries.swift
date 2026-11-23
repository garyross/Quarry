import AppKit
import Observation
import QuarryKit

/// The Save Query sheet (S-034): a name, and which part of the editor to save.
@Observable
@MainActor
final class SaveQueryDraft: Identifiable {
    enum Part: Hashable { case statement, editor }

    let id = UUID()
    var name: String
    var part: Part = .statement
    /// The selection, or the statement ⌘R would run.
    let statement: String
    let editor: String
    /// Names in use (Replace rather than Save).
    let usedNames: [String]

    init(statement: String, editor: String, usedNames: [String]) {
        self.statement = statement
        self.editor = editor
        self.usedNames = usedNames
        name = SavedQueryFile.defaultName(for: statement.isEmpty ? editor : statement)
        if statement.isEmpty { part = .editor }
    }

    /// The editor holds more than the current statement.
    var offersChoice: Bool { !statement.isEmpty && statement != editor }
    var text: String { part == .statement && !statement.isEmpty ? statement : editor }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var replaces: Bool { usedNames.contains { $0.compare(trimmedName, options: .caseInsensitive) == .orderedSame } }
    var canSave: Bool { !trimmedName.isEmpty && !text.isEmpty }
}

/// Saved queries (S-034): Save Query… (⌃⇧⌘S), Query > Saved Queries and the
/// run bar's popover insert one; Manage Saved Queries… (⌃⌥⌘S) opens their window.
extension Session {
    /// Save Query…: the sheet, over the selection or the current statement.
    func beginSaveQuery() {
        guard let model else { return }
        view = .query
        query.showsSavedQueries = false
        let editor = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !editor.isEmpty else { NSSound.beep(); return }
        saveQueryDraft = SaveQueryDraft(statement: currentStatementText(), editor: editor,
                                        usedNames: model.savedQueries.map(\.name))
    }

    /// The selection if there is one, else the statement at the cursor, with its semicolon.
    func currentStatementText() -> String {
        let text = query.text as NSString
        let selection = query.selection
        if selection.length > 0, NSMaxRange(selection) <= text.length {
            return text.substring(with: selection).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let statements = StatementSplitter.split(query.text)
        guard let statement = StatementSplitter.statement(at: query.cursor, in: statements) else { return "" }
        return statements.count == 1 ? query.text.trimmingCharacters(in: .whitespacesAndNewlines) : statement.text + ";"
    }

    func saveQuery() {
        guard let model, let draft = saveQueryDraft, draft.canSave else { return }
        model.saveQuery(draft.text, named: draft.trimmedName)
        saveQueryDraft = nil
    }

    /// A saved query picked from the menu or the popover goes in place of the selection, selected.
    func insertSavedQuery(_ text: String) {
        view = .query
        query.showsSavedQueries = false
        query.historyStepper.reset()
        query.insertActionName = "Insert Saved Query"
        query.insertRequest = text
    }
}
