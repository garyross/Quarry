import QuarryKit
import SwiftUI

/// The run bar's Saved Queries popover (S-034): a search field over every
/// saved query, by name. A click inserts one in place of the selection;
/// Save Query… and Manage… sit at the bottom.
struct SavedQueriesPopover: View {
    @Environment(Session.self) private var session
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""

    var body: some View {
        let all = model.savedQueries
        let shown = all.filter { !QueryHistory.matches(search, in: [$0.name + " " + $0.text]).isEmpty }
        VStack(spacing: 0) {
            TextField("Search Saved Queries", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search saved queries")
                .padding(Space.sm)
            Divider()
            if all.isEmpty {
                ContentUnavailableView("No Saved Queries", systemImage: "bookmark",
                                       description: Text("Save a query with ⌃⇧⌘S to use it again on any server."))
                    .frame(maxHeight: .infinity)
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxHeight: .infinity)
            } else {
                List(shown) { saved in
                    Button {
                        session.insertSavedQuery(saved.text)
                    } label: {
                        SavedQueryRow(saved: saved)
                    }
                    .buttonStyle(.plain)
                    .help("Insert in place of the selection")
                }
                .listStyle(.plain)
            }
            Divider()
            HStack(spacing: Space.sm) {
                Button("Save Query…") { session.beginSaveQuery() }
                    .disabled(!session.query.hasText)
                    .help("Save the current statement or the editor by name (⌃⇧⌘S)")
                Spacer()
                Button("Manage…") {
                    session.query.showsSavedQueries = false
                    openWindow(id: SavedQueriesWindow.sceneID)
                }
                .help("Rename, edit, import and export saved queries (⌃⌥⌘S)")
            }
            .controlSize(.small)
            .padding(Space.sm)
        }
        .frame(width: 440, height: 360)
    }
}

/// A saved query's name over its first line.
struct SavedQueryRow: View {
    let saved: SavedQuery

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(saved.name)
                .lineLimit(1)
            Text(QueryHistory.summary(saved.text))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.xs)
        .contentShape(Rectangle())
    }
}
