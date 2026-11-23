import AppKit
import QuarryKit
import SwiftUI

/// The Query menu: running, the editor's helpers, history and saved queries.
struct QueryCommands: Commands {
    @ObservedObject var state: MenuState
    let model: AppModel
    private var menu: MenuState.Snapshot { state.snapshot }
    @Environment(\.openWindow) private var openWindow
    private var session: Session? { MenuState.shared.active }

    var body: some Commands {
        CommandMenu("Query") {
            Button("Run Current Statement") {
                session?.view = .query
                session?.runCurrentStatement()
            }
            .keyboardShortcut("r")
            .disabled(!menu.canRunQuery)
            Button("Run All") {
                session?.view = .query
                session?.runAll()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!menu.canRunQuery)
            Button(EditorCommand.selectStatement.title) { session?.query.editorCommand = .selectStatement }
                .keyboardShortcut("y", modifiers: .control)
                .disabled(!menu.canShowCompletions)
            Button("Show Completions") { session?.query.completionRequest = true }
                .keyboardShortcut(.escape, modifiers: .option)
                .disabled(!menu.canShowCompletions)
            Divider()
            // S-032: also caught by the editor itself, so they work in sheets' SQL editors.
            Button(EditorCommand.commentLine.title) { session?.query.editorCommand = .commentLine }
                .keyboardShortcut("/")
                .disabled(!menu.canShowCompletions)
            Button(EditorCommand.commentStatement.title) { session?.query.editorCommand = .commentStatement }
                .keyboardShortcut("/", modifiers: [.command, .option])
                .disabled(!menu.canShowCompletions)
            Button(EditorCommand.shiftRight.title) { session?.query.editorCommand = .shiftRight }
                .keyboardShortcut(menu.view == .query ? KeyboardShortcut("]") : nil)
                .disabled(!menu.canShowCompletions)
            Button(EditorCommand.shiftLeft.title) { session?.query.editorCommand = .shiftLeft }
                .keyboardShortcut(menu.view == .query ? KeyboardShortcut("[") : nil)
                .disabled(!menu.canShowCompletions)
            Divider()
            // S-033. Sequel Pro used ⌃↑ ⌃↓, which Mission Control and App Exposé take first.
            Button("Previous Query from History") { session?.stepHistory(older: true) }
                .keyboardShortcut(.upArrow, modifiers: [.control, .option])
                .disabled(!menu.canShowCompletions || !menu.hasQueryHistory)
            Button("Next Query from History") { session?.stepHistory(older: false) }
                .keyboardShortcut(.downArrow, modifiers: [.control, .option])
                .disabled(!menu.canShowCompletions || !menu.hasQueryHistory)
            Button("Show History") {
                session?.view = .query
                session?.query.showsHistory = true
            }
            .keyboardShortcut("h", modifiers: [.command, .control])
            .disabled(menu.phase != .connected)
            Divider()
            // S-034. Saved queries belong to the Mac, so the list needs no session.
            Button("Save Query…") { session?.beginSaveQuery() }
                .keyboardShortcut("s", modifiers: [.command, .shift, .control])
                .disabled(!menu.canShowCompletions || !menu.hasQueryText)
            Menu("Saved Queries") {
                if model.savedQueries.isEmpty {
                    Button("No Saved Queries") {}.disabled(true)
                }
                ForEach(model.savedQueries) { saved in
                    Button(saved.name) { session?.insertSavedQuery(saved.text) }
                        .disabled(menu.phase != .connected)
                }
            }
            Button("Manage Saved Queries…") { openWindow(id: SavedQueriesWindow.sceneID) }
                .keyboardShortcut("s", modifiers: [.command, .option, .control])
            Divider()
            Button("Cancel Query") { session?.cancelQuery() }
                .keyboardShortcut(".")
                .disabled(!menu.canCancelQuery)
        }
    }
}
