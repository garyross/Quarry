import QuarryKit
import QuarryControllers
import SwiftUI

/// Structure (⌘1): fields above indexes. On a table the fields are edited
/// in place, in the Edit Field sheet, or dragged to reorder (S-023).
struct StructureView: View {
    @Environment(Session.self) private var session

    var body: some View {
        let structure = session.structure
        VSplitView {
            fieldsGrid(structure)
                .frame(minHeight: 160)
            VStack(spacing: 0) {
                indexesHeader(structure)
                indexesGrid(structure)
            }
            .frame(minHeight: 120, idealHeight: 200)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let error = structure.editError {
                    EditErrorBar(error: error) { structure.editError = nil }
                }
                statusBar(structure)
            }
        }
        .alert(deleteTitle(structure), isPresented: Binding(get: { structure.pendingDelete != nil },
                                                             set: { if !$0 { structure.pendingDelete = nil } })) {
            Button("Delete", role: .destructive) { session.confirmDeleteFields() }
            Button("Cancel", role: .cancel) { structure.pendingDelete = nil }
        } message: {
            Text("Every value in \((structure.pendingDelete?.count ?? 0) == 1 ? "it" : "them") is lost. This can’t be undone.")
        }
        .sheet(item: Binding(get: { structure.fieldSheet }, set: { structure.fieldSheet = $0 })) { draft in
            FieldSheet(draft: draft,
                       save: { session.saveFieldSheet() }, close: { structure.fieldSheet = nil })
                .noInitialFocus()
        }
        .alert(StructureController.deleteIndexTitle(structure.pendingIndexDelete ?? []),
               isPresented: Binding(get: { structure.pendingIndexDelete != nil },
                                    set: { if !$0 { structure.pendingIndexDelete = nil } })) {
            Button("Delete", role: .destructive) { session.confirmDeleteIndexes() }
            Button("Cancel", role: .cancel) { structure.pendingIndexDelete = nil }
        } message: {
            Text("The fields and their values stay. Queries that used \((structure.pendingIndexDelete?.count ?? 0) == 1 ? "it" : "them") may run slower.")
        }
        .alert(StructureController.rebuildTitle(session.selectedObject?.name ?? ""),
               isPresented: Binding(get: { structure.pendingRebuild != nil },
                                    set: { if !$0, structure.pendingRebuild != nil { structure.cancelRebuild() } })) {
            Button("Rebuild") { session.confirmRebuild() }
            Button("Cancel", role: .cancel) { structure.cancelRebuild() }
        } message: {
            Text(StructureController.rebuildMessage(rows: structure.pendingRebuild?.rows ?? 0))
        }
        .sheet(item: Binding(get: { structure.indexSheet }, set: { structure.indexSheet = $0 })) { draft in
            IndexSheet(draft: draft,
                       save: { session.saveIndexSheet() }, close: { structure.indexSheet = nil })
                .noInitialFocus()
        }
    }

    /// "Indexes" with + and − for a table (S-024).
    private func indexesHeader(_ structure: StructureController) -> some View {
        HStack(spacing: Space.xs) {
            Text("Indexes")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if session.selectedObject?.kind == .table {
                Button("Add Index", systemImage: "plus") { session.requestAddIndex() }
                    .disabled(!structure.canAddIndex)
                    .help("Add an index on the selected fields (⌃⌥⌘A)")
                Button("Delete Index", systemImage: "minus") { session.requestDeleteIndexes() }
                    .disabled(!structure.canDeleteIndexes)
                    .help("Delete the selected indexes (⌘⌫)")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }

    private func indexesGrid(_ structure: StructureController) -> GridPane {
        let session = session
        let isTable = session.selectedObject?.kind == .table
        let reports = DataGrid.Reports(selection: { structure.indexSelection = $0 },
                                       focus: { structure.indexGridHasFocus = $0 })
        let actions = DataGrid.RowActions(canAdd: { structure.canAddIndex }, canDuplicate: { false },
                                          canDelete: { structure.canDeleteIndexes },
                                          add: { session.requestAddIndex() }, duplicate: {},
                                          delete: { session.requestDeleteIndexes() },
                                          noun: "Index", addsWithSheet: true, duplicates: false, plural: "Indexes",
                                          deleteCount: { structure.selectedIndexNames.count })
        return GridPane(data: structure.indexes, load: LoadState(loadedFor: structure.load.loadedFor),
                        emptyTitle: "No Indexes", emptySymbol: "key",
                        rowActions: isTable ? actions : nil, reports: reports,
                        selectRequest: structure.indexSelectRequest.map { ($0.row, $0.id) },
                        emptyAction: isTable && structure.canAddIndex ? ("Add Index", { session.requestAddIndex() }) : nil)
    }

    private func fieldsGrid(_ structure: StructureController) -> GridPane {
        let session = session
        let editing = DataGrid.Editing(canEdit: { structure.canEdit(row: $0, column: $1) },
                                       text: { structure.editingText(row: $0, column: $1) },
                                       save: { session.editField(row: $0, column: $1, to: $2) })
        let reports = DataGrid.Reports(selection: { structure.selection = $0 }, focus: { structure.gridHasFocus = $0 })
        let actions = DataGrid.RowActions(canAdd: { structure.canAddField }, canDuplicate: { structure.canDuplicateField },
                                          canDelete: { structure.canDeleteFields },
                                          add: { session.requestAddField() }, duplicate: { session.duplicateField() },
                                          delete: { session.requestDeleteFields() },
                                          noun: "Field", addsWithSheet: true,
                                          edit: { row in session.requestEditField(row: row) })
        let reorder = DataGrid.RowReorder(canDrag: { structure.canDrag(row: $0) },
                                          move: { session.moveField(from: $0, to: $1) })
        let isTable = structure.canEdit || session.selectedObject?.kind == .table
        return GridPane(data: structure.fields, load: structure.load, emptyTitle: "No Fields",
                        emptySymbol: "list.bullet.rectangle",
                        editing: isTable ? editing : nil, rowActions: isTable ? actions : nil, reports: reports,
                        selectRequest: structure.selectRequest.map { ($0.row, $0.id) },
                        reorder: isTable ? reorder : nil)
    }

    private func deleteTitle(_ structure: StructureController) -> String {
        let names = structure.pendingDelete ?? []
        return names.count == 1 ? "Delete the field \u{201C}\(names[0])\u{201D}?" : "Delete \(names.count) fields?"
    }

    private func statusBar(_ structure: StructureController) -> some View {
        StatusBar(text: StatementResult.formatCount(structure.fields.rows.count, "field"),
                  isLoading: structure.load.isLoading || structure.isChanging, leading: {
            if session.selectedObject?.kind == .table {
                HStack(spacing: Space.xs) {
                    Button("Add Field", systemImage: "plus") { session.requestAddField() }
                        .disabled(!structure.canAddField)
                        .help("Add a field after the selected one (⌥⌘A)")
                    Button("Delete Field", systemImage: "minus") { session.requestDeleteFields() }
                        .disabled(!structure.canDeleteFields)
                        .help("Delete the selected fields (⌘⌫)")
                    Button("Duplicate Field", systemImage: "plus.square.on.square") { session.duplicateField() }
                        .disabled(!structure.canDuplicateField)
                        .help("Copy the selected field, right after it (⌥⇧⌘D)")
                    Button("Edit Field", systemImage: "pencil") { session.requestEditField() }
                        .disabled(!structure.canEditField)
                        .help("Change every part of the selected field in a sheet (⌥⌘E)")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                Divider().frame(height: Space.md)
            }
        }, trailing: { EmptyView() })
    }
}
