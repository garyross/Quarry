import AppKit
import QuarryKit
import SwiftUI
import UniformTypeIdentifiers

/// Manage Saved Queries… (S-034, ⌃⌥⌘S): every saved query on the left, the
/// selected one's name and SQL on the right. Edits save as you type. The …
/// menu duplicates, saves to a file, imports and exports.
struct SavedQueriesWindow: View {
    static let sceneID = "saved-queries"

    @Environment(AppModel.self) private var model
    @State private var selection: Set<UUID> = []
    @State private var confirm: Confirm?
    @State private var importProblem: String?

    enum Confirm: Identifiable {
        case delete(Set<UUID>), deleteAll, importReplacing
        var id: String {
            switch self {
            case .delete: "delete"
            case .deleteAll: "deleteAll"
            case .importReplacing: "importReplacing"
            }
        }
    }

    private var selected: [SavedQuery] { model.savedQueries.filter { selection.contains($0.uid) } }

    var body: some View {
        NavigationSplitView {
            list
                .navigationSplitViewColumnWidth(min: 180, ideal: Layout.savedQueriesListWidth, max: 320)
        } detail: {
            detail
        }
        .toolbar { toolbar }
        .frame(minWidth: Layout.savedQueriesMinWidth, minHeight: Layout.savedQueriesMinHeight)
        .noInitialFocus()
        .onAppear { if selection.isEmpty, let first = model.savedQueries.first { selection = [first.uid] } }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { action in
            switch action {
            case .delete(let uids):
                Button("Delete", role: .destructive) { delete(uids) }
            case .deleteAll:
                Button("Delete All", role: .destructive) { delete(Set(model.savedQueries.map(\.uid))) }
            case .importReplacing:
                Button("Choose File…", role: .destructive) { importFile(replacing: true) }
            }
        } message: { action in
            switch action {
            case .importReplacing: Text("The file’s queries replace all \(countText(model.savedQueries.count)). You can’t undo this.")
            default: Text("You can’t undo this.")
            }
        }
        .alert("Couldn’t import saved queries", isPresented: Binding(get: { importProblem != nil }, set: { if !$0 { importProblem = nil } })) {
            Button("OK") { importProblem = nil }
        } message: {
            Text(importProblem ?? "")
        }
    }

    private var list: some View {
        List(model.savedQueries, selection: $selection) { saved in
            SavedQueryRow(saved: saved)
                .tag(saved.uid)
                .contextMenu {
                    let targets = selection.contains(saved.uid) ? selection : [saved.uid]
                    Button("Duplicate") { duplicate(targets) }
                    Button("Save Query to File…") { saveToFile(saved) }
                        .disabled(targets.count > 1)
                    Divider()
                    Button(targets.count > 1 ? "Delete \(targets.count) Queries…" : "Delete") { requestDelete(targets) }
                }
        }
        .onDeleteCommand { requestDelete(selection) }
        .overlay {
            if model.savedQueries.isEmpty {
                ContentUnavailableView {
                    Label("No Saved Queries", systemImage: "bookmark")
                } description: {
                    Text("Save a query from Query with ⌃⇧⌘S, or import a file.")
                } actions: {
                    Button("Import…") { importFile(replacing: false) }
                }
            }
        }
        .accessibilityLabel("Saved queries")
    }

    @ViewBuilder
    private var detail: some View {
        if selected.count == 1, let saved = selected.first {
            SavedQueryEditor(saved: saved)
                .id(saved.uid)
        } else if selected.count > 1 {
            ContentUnavailableView("\(selected.count) Saved Queries", systemImage: "bookmark",
                                   description: Text("Export them, or press Delete to remove them."))
        } else {
            ContentUnavailableView("No Selection", systemImage: "bookmark",
                                   description: Text("Choose a saved query to edit it."))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                selection = [model.addSavedQuery().uid]
            } label: {
                Label("New Query", systemImage: "plus")
            }
            .help("Add an empty saved query")
            Button {
                requestDelete(selection)
            } label: {
                Label("Delete", systemImage: "minus")
            }
            .disabled(selection.isEmpty)
            .help("Delete the selected saved queries (⌫)")
            Menu {
                Button("Duplicate") { duplicate(selection) }
                    .disabled(selection.isEmpty)
                Button("Save Query to File…") { selected.first.map(saveToFile) }
                    .disabled(selected.count != 1)
                Divider()
                Button(selection.count > 1 ? "Export \(selection.count) Selected…" : "Export Selected…") { export(selected) }
                    .disabled(selection.isEmpty)
                Button("Import…") { importFile(replacing: false) }
                Button("Import by Replacing…") { confirm = .importReplacing }
                    .disabled(model.savedQueries.isEmpty)
                Divider()
                Button("Delete All…", role: .destructive) { confirm = .deleteAll }
                    .disabled(model.savedQueries.isEmpty)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Duplicate, save, import or export saved queries")
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case .delete(let uids): "Delete \(countText(uids.count))?"
        case .deleteAll: "Delete all \(countText(model.savedQueries.count))?"
        case .importReplacing: "Replace every saved query with a file’s?"
        case nil: ""
        }
    }

    private func countText(_ count: Int) -> String { count == 1 ? "1 saved query" : "\(count) saved queries" }

    private func requestDelete(_ uids: Set<UUID>) {
        // One goes at once, as in Sequel Pro; several ask first.
        if uids.count == 1 { delete(uids) } else if !uids.isEmpty { confirm = .delete(uids) }
    }

    private func delete(_ uids: Set<UUID>) {
        model.deleteSavedQueries(uids)
        selection.subtract(uids)
        if selection.isEmpty, let first = model.savedQueries.first { selection = [first.uid] }
    }

    private func duplicate(_ uids: Set<UUID>) {
        let copies = model.savedQueries.filter { uids.contains($0.uid) }.compactMap { model.duplicateSavedQuery($0.uid) }
        if !copies.isEmpty { selection = Set(copies.map(\.uid)) }
    }

    private func saveToFile(_ saved: SavedQuery) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = "\(saved.name).sql"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try saved.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func export(_ queries: [SavedQuery]) {
        guard !queries.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: SavedQueryFile.fileExtension) ?? .propertyList]
        panel.nameFieldStringValue = queries.count == 1 ? "\(queries[0].name).spf" : "Saved Queries.spf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SavedQueryFile.encode(queries.map(\.item)).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func importFile(replacing: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: SavedQueryFile.fileExtension), UTType(filenameExtension: "sql")]
            .compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.message = replacing ? "The chosen files’ queries replace every saved query." : "Choose .spf files (from Quarry or Sequel Pro) or .sql files."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            let items = try panel.urls.flatMap(SavedQueriesWindow.items(in:))
            let added = model.importSavedQueries(items, replacing: replacing)
            selection = Set(added.map(\.uid))
        } catch {
            importProblem = error.localizedDescription
        }
    }

    /// The saved queries in one file: an .spf's list, or a whole .sql file as one.
    static func items(in url: URL) throws -> [SavedQueryFile.Item] {
        if url.pathExtension.lowercased() == "sql" {
            let text = try String(contentsOf: url, encoding: .utf8)
            return [try SavedQueryFile.sqlItem(fileName: url.lastPathComponent, text: text)]
        }
        return try SavedQueryFile.decode(try Data(contentsOf: url))
    }
}

/// One saved query's name and SQL. Edits save as you type; the list resorts
/// once typing pauses.
private struct SavedQueryEditor: View {
    @Bindable var saved: SavedQuery
    @Environment(AppModel.self) private var model
    @State private var cursor = 0
    @State private var selectRequest: NSRange?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $saved.name, prompt: Text("Required"))
                    .help("Shown in Query > Saved Queries")
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            .scrollDisabled(true)
            SQLEditor(text: $saved.text, cursor: $cursor, selectRequest: $selectRequest, errorLine: nil,
                      accessibilityLabel: "Saved query SQL")
                .overlay(alignment: .top) { Divider() }
        }
        .task(id: saved.name + "\u{0}" + saved.text) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saved.updatedAt = .now
            model.commitSavedQueries()
        }
        .onDisappear {
            guard saved.modelContext != nil, !saved.isDeleted else { return }
            if saved.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                saved.name = SavedQueryFile.uniqueName(SavedQueryFile.defaultName(for: saved.text),
                                                       among: model.savedQueries.filter { $0 !== saved }.map(\.name))
            }
            model.commitSavedQueries()
        }
    }
}
