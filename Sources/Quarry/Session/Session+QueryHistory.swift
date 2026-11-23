import AppKit
import QuarryKit
import UniformTypeIdentifiers

/// Query history (S-033): every run is recorded for the server and user;
/// Previous and Next Query from History (⌃⌥↑ ⌃⌥↓) step through it in the
/// editor, and the run bar's History popover (⌃⌘H) searches it.
extension Session {
    /// The server and user history belongs to.
    var historyKey: String? { connectedDetails.map(FavoriteDatabase.serverKey(for:)) }

    /// This server's history, newest first.
    var queryHistory: [QueryHistoryEntry] { model?.history(for: historyKey) ?? [] }

    func recordHistory(_ statements: [SQLStatement]) {
        guard let model, let historyKey, let entry = QueryHistory.entry(for: statements.map(\.text)) else { return }
        model.addHistory(entry, serverKey: historyKey, database: database)
        query.historyStepper.reset()
    }

    /// Previous (older) or Next (newer) Query from History: replaces the
    /// selection with the entry and selects it, so the next step replaces it again.
    /// Beeps at either end.
    func stepHistory(older: Bool) {
        let entries = queryHistory
        let index = older ? query.historyStepper.previous(count: entries.count)
                          : query.historyStepper.next(count: entries.count)
        guard let index else { NSSound.beep(); return }
        view = .query
        query.isInsertingHistory = true
        query.insertActionName = "Insert Query from History"
        query.insertRequest = entries[index].text
    }

    /// Typing or any edit other than a history step starts again from the newest entry.
    func queryTextChanged() {
        if query.isInsertingHistory {
            query.isInsertingHistory = false
        } else {
            query.historyStepper.reset()
        }
    }

    /// A query picked in the History popover goes in at the cursor, selected.
    func insertFromHistory(_ text: String) {
        view = .query
        query.showsHistory = false
        query.historyStepper.reset()
        query.insertActionName = "Insert Query from History"
        query.insertRequest = text
    }

    func copyHistory() {
        let script = QueryHistory.script(queryHistory.map(\.text))
        guard !script.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script, forType: .string)
    }

    /// Save History…: the history as an .sql file, oldest first.
    func saveHistory() {
        let script = QueryHistory.script(queryHistory.map(\.text))
        guard !script.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = "\(connectionName.isEmpty ? "Query" : connectionName) History.sql"
        query.showsHistory = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func clearHistory() {
        guard let model, let historyKey else { return }
        model.clearHistory(for: historyKey)
        query.historyStepper.reset()
    }
}
