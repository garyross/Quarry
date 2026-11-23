import QuarryKit
import QuarryControllers
import SwiftUI

/// Foreign Keys (⌘3): the table's foreign keys; add one in a sheet, delete the selected ones (S-025).
struct ForeignKeysView: View {
    @Environment(Session.self) private var session

    var body: some View {
        let keys = session.foreignKeys
        grid(keys)
            .overlay {
                if let note = keys.engineNote, keys.grid.rows.isEmpty {
                    ContentUnavailableView("Foreign Keys Need InnoDB", systemImage: "link", description: Text(note))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let error = keys.editError {
                        EditErrorBar(error: error) { keys.editError = nil }
                    }
                    statusBar(keys)
                }
            }
            .alert(ForeignKeysController.deleteTitle(keys.pendingDelete ?? []),
                   isPresented: Binding(get: { keys.pendingDelete != nil }, set: { if !$0 { keys.pendingDelete = nil } })) {
                Button("Delete", role: .destructive) { session.confirmDeleteForeignKeys() }
                Button("Cancel", role: .cancel) { keys.pendingDelete = nil }
            } message: {
                Text("The fields, their values and indexes stay.")
            }
            .alert(StructureController.rebuildTitle(session.selectedObject?.name ?? ""),
                   isPresented: Binding(get: { keys.pendingRebuild != nil },
                                        set: { if !$0, keys.pendingRebuild != nil { keys.cancelRebuild() } })) {
                Button("Rebuild") { session.confirmForeignKeyRebuild() }
                Button("Cancel", role: .cancel) { keys.cancelRebuild() }
            } message: {
                Text(StructureController.rebuildMessage(rows: keys.pendingRebuild?.rows ?? 0, noun: "foreign key"))
            }
            .sheet(item: Binding(get: { keys.sheet }, set: { keys.sheet = $0 })) { draft in
                ForeignKeySheet(draft: draft,
                                tableChanged: { session.foreignKeyTableChanged() },
                                save: { session.saveForeignKeySheet() }, close: { keys.sheet = nil })
                    .noInitialFocus()
            }
    }

    private func grid(_ keys: ForeignKeysController) -> GridPane {
        let session = session
        let reports = DataGrid.Reports(selection: { keys.selection = $0 }, focus: { keys.gridHasFocus = $0 })
        let actions = DataGrid.RowActions(canAdd: { keys.canAdd }, canDuplicate: { false }, canDelete: { keys.canDelete },
                                          add: { session.requestAddForeignKey() }, duplicate: {},
                                          delete: { session.requestDeleteForeignKeys() },
                                          noun: "Foreign Key", addsWithSheet: true, duplicates: false)
        let emptyAction: (title: String, action: () -> Void)? = keys.canAdd
            ? ("Add Foreign Key", { session.requestAddForeignKey() }) : nil
        return GridPane(data: keys.grid, load: keys.engineNote == nil ? keys.load : LoadState(),
                        emptyTitle: "No Foreign Keys", emptySymbol: "link",
                        rowActions: keys.supportsKeys ? actions : nil, reports: reports,
                        selectRequest: keys.selectRequest.map { ($0.row, $0.id) }, emptyAction: emptyAction)
    }

    private func statusBar(_ keys: ForeignKeysController) -> some View {
        StatusBar(text: StatementResult.formatCount(keys.grid.rows.count, "foreign key"),
                  isLoading: keys.load.isLoading || keys.isChanging, leading: {
            HStack(spacing: Space.xs) {
                Button("Add Foreign Key", systemImage: "plus") { session.requestAddForeignKey() }
                    .disabled(!keys.canAdd)
                    .help(keys.supportsKeys ? "Link a field to a field of another table (⌥⌘A)"
                          : "Foreign keys need a table that uses InnoDB")
                Button("Delete Foreign Key", systemImage: "minus") { session.requestDeleteForeignKeys() }
                    .disabled(!keys.canDelete)
                    .help("Delete the selected foreign keys (⌘⌫)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            Divider().frame(height: Space.md)
        }, trailing: { EmptyView() })
    }
}
