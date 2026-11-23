import QuarryKit
import SwiftUI

/// The run bar's History popover (S-033, ⌃⌘H): a search field over this
/// server's past queries, newest first. Clicking one puts it in the editor at
/// the cursor; the … menu copies, saves or clears the history.
struct QueryHistoryPopover: View {
    @Environment(Session.self) private var session
    @State private var search = ""
    @State private var confirmsClear = false

    var body: some View {
        let entries = session.queryHistory
        let shown = entries.filter { !QueryHistory.matches(search, in: [$0.text]).isEmpty }
        VStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                TextField("Search History", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search history")
                Menu {
                    Button("Copy History") { session.copyHistory() }
                    Button("Save History…") { session.saveHistory() }
                    Divider()
                    Button("Clear History…", role: .destructive) { confirmsClear = true }
                } label: {
                    Label("History Actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(entries.isEmpty)
                .help("Copy, save or clear this server's history")
            }
            .padding(Space.sm)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock",
                                       description: Text("Queries you run on this server appear here."))
                    .frame(maxHeight: .infinity)
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxHeight: .infinity)
            } else {
                List(shown) { entry in
                    Button {
                        session.insertFromHistory(entry.text)
                    } label: {
                        HistoryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .help("Insert at the cursor")
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 440, height: 360)
        .confirmationDialog("Clear the query history for this server?", isPresented: $confirmsClear) {
            Button("Clear History", role: .destructive) { session.clearHistory() }
        } message: {
            Text("This removes \(entries.count == 1 ? "1 query" : "\(entries.count) queries") for every connection to this server and user. You can't undo this.")
        }
    }
}

private struct HistoryRow: View {
    let entry: QueryHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(QueryHistory.summary(entry.text))
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.tail)
            HStack(spacing: Space.xs) {
                Text(entry.ranAt, format: .relative(presentation: .named))
                if !entry.database.isEmpty { Text("· \(entry.database)") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.xs)
        .contentShape(Rectangle())
    }
}
