import QuarryKit
import QuarryControllers
import SwiftUI

/// Content (⌘2): one page of rows, sorted on the server.
struct TableContentView: View {
    @Environment(Session.self) private var session

    var body: some View {
        let content = session.content
        grid(content)
            .safeAreaInset(edge: .top, spacing: 0) { FilterBar() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let error = content.editError {
                        EditErrorBar(error: error) { content.editError = nil }
                    }
                    statusBar(content)
                }
            }
            .alert(deleteTitle(content), isPresented: Binding(get: { content.pendingDelete != nil },
                                                               set: { if !$0 { content.pendingDelete = nil } })) {
                Button("Delete", role: .destructive) { session.confirmDeleteRows() }
                Button("Cancel", role: .cancel) { content.pendingDelete = nil }
            } message: {
                Text("This can't be undone.")
            }
    }

    private func grid(_ content: ContentController) -> GridPane {
        let session = session
        let editing = DataGrid.Editing(canEdit: content.canEdit, text: content.editingText,
                                       save: { session.editContent(row: $0, column: $1, to: $2) },
                                       endRow: { session.endRowEdit(row: $0, cancelled: $1) })
        let reports = DataGrid.Reports(selection: { content.selection = $0 }, focus: { content.gridHasFocus = $0 })
        let request: (row: Int, column: Int, id: UUID)? = content.editRequest.map { ($0.row, $0.column, $0.id) }
        let filtered = content.isFiltered
        let emptyAction: (title: String, action: () -> Void)? = filtered ? ("Clear Filter", { session.clearFilter() })
            : content.canAddRow ? ("Add Row", { session.addRow() }) : nil
        return GridPane(data: content.grid, load: content.load, emptyTitle: filtered ? "No Matching Rows" : "No Rows",
                        emptySymbol: filtered ? "line.3.horizontal.decrease" : "tablecells",
                        sort: content.sortColumn.map { ($0, content.ascending) },
                        onSort: { session.sortContent(by: $0, ascending: $1) },
                        editing: editing, rowActions: content.isTable ? rowActions : nil,
                        insertTable: session.selectedObject.map { DataGrid.InsertTarget(table: $0.name, engine: session.engine) }, reports: reports,
                        editRequest: request,
                        fieldEditor: DataGrid.FieldEditorHook(opens: content.opensFieldEditor,
                                                              open: { session.openFieldEditor(row: $0, column: $1, typed: $2) }),
                        links: DataGrid.LinkHook(help: content.linkHelp,
                                                 follow: { row, column, newTab in
                                                     if newTab { session.followLinkInNewTab(row: row, column: column) }
                                                     else { session.followLink(row: row, column: column) }
                                                 }),
                        emptyAction: emptyAction)
    }

    private var rowActions: DataGrid.RowActions {
        let content = session.content
        return DataGrid.RowActions(canAdd: { content.canAddRow }, canDuplicate: { content.canDuplicateRow },
                                   canDelete: { content.canDeleteRows },
                                   add: { session.addRow() }, duplicate: { session.duplicateRow() },
                                   delete: { session.deleteRows() })
    }

    private func deleteTitle(_ content: ContentController) -> String {
        let count = content.pendingDelete?.count ?? 0
        return count == 1 ? "Delete this row?" : "Delete \(count) rows?"
    }

    private func statusBar(_ content: ContentController) -> some View {
        StatusBar(text: content.statusLabel, isLoading: content.isLoading) {
            if content.isTable {
                HStack(spacing: Space.xs) {
                    Button("Add Row", systemImage: "plus") { session.addRow() }
                        .disabled(!content.canAddRow)
                        .help("Add a row with the table's default values (⌥⌘A)")
                    Button("Delete Row", systemImage: "minus") { session.deleteRows() }
                        .disabled(!content.canDeleteRows)
                        .help("Delete the selected rows (⌘⌫)")
                    Button("Duplicate Row", systemImage: "plus.square.on.square") { session.duplicateRow() }
                        .disabled(!content.canDuplicateRow)
                        .help("Copy the selected row into a new row (⌥⇧⌘D)")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                Divider().frame(height: Space.md)
            }
        } trailing: {
            Button("Previous Page", systemImage: "chevron.backward") { session.movePage(by: -1) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!content.paging.hasPrevious || content.isLoading)
                .help("Show the previous \(content.paging.pageSize.formatted()) rows (⌥⌘[)")
            Text("Page \(content.paging.page + 1) of \(content.paging.pageCount)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Next Page", systemImage: "chevron.forward") { session.movePage(by: 1) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!content.paging.hasNext || content.isLoading)
                .help("Show the next \(content.paging.pageSize.formatted()) rows (⌥⌘])")
        }
    }
}

/// Why an edit failed, above Content's status bar, until dismissed or the next edit.
struct EditErrorBar: View {
    let error: DatabaseError
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            ErrorMessage(error: error)
            Spacer(minLength: Space.sm)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Hide this message")
        }
        .font(.callout)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(StatusStyle.error.opacity(0.10))
        .overlay(alignment: .top) { Divider() }
    }
}
