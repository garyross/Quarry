import QuarryKit
import SwiftUI

/// Query (⌘6): the SQL editor above its results.
struct QueryView: View {
    @Environment(Session.self) private var session
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var query = session.query
        VSplitView {
            SQLEditor(text: $query.text, cursor: $query.cursor,
                      selectRequest: $query.selectRequest, errorLine: session.query.errorLine,
                      completions: { text, cursor, explicit in session.completions(text, cursor: cursor, explicit: explicit) },
                      completionRequest: $query.completionRequest,
                      completionRevision: session.query.completionRevision,
                      editorCommand: $query.editorCommand,
                      insertRequest: $query.insertRequest,
                      insertActionName: session.query.insertActionName,
                      selection: $query.selection)
                .overlay(alignment: .topLeading) {
                    if session.query.text.isEmpty {
                        Text("Type SQL and press ⌘R to run it")
                            .font(.system(size: DataStyle.editorSize, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 40 + Space.sm)
                            .padding(.top, Space.sm)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 120, idealHeight: 260)
                .task(id: session.database) { session.refreshCompletionCatalog() }
                .onChange(of: session.query.text) { session.queryTextChanged() }
            VStack(spacing: 0) {
                runBar
                if let error = session.query.error {
                    errorBar(error)
                }
                if let error = session.query.editError {
                    EditErrorBar(error: error) { session.query.editError = nil }
                }
                results
            }
            .frame(minHeight: 160)
        }
    }

    private var runBar: some View {
        @Bindable var query = session.query
        return HStack(spacing: Space.sm) {
            Button {
                session.runCurrentStatement()
            } label: {
                Label("Run Current Statement", systemImage: "play.fill")
            }
            .help("Run the statement at the cursor (⌘R)")
            .disabled(session.query.isRunning)
            Button("Run All") { session.runAll() }
                .help("Run every statement in order (⌥⌘R)")
                .disabled(session.query.isRunning)
            if session.query.isRunning {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel(session.query.isCancelling ? "Cancelling" : "Running")
                Button("Cancel") { session.cancelQuery() }
                    .help("Stop the query on the server (⌘.)")
                    .disabled(session.query.isCancelling)
            }
            Button {
                session.query.showsHistory.toggle()
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .help("Search the queries run on this server (⌃⌘H)")
            .popover(isPresented: $query.showsHistory, arrowEdge: .bottom) {
                QueryHistoryPopover()
                    .environment(session)
            }
            Button {
                session.query.showsSavedQueries.toggle()
            } label: {
                Label("Saved Queries", systemImage: "bookmark")
            }
            .help("Insert or save a query kept by name")
            .popover(isPresented: $query.showsSavedQueries, arrowEdge: .bottom) {
                SavedQueriesPopover()
                    .environment(session)
                    .environment(model)
            }
            Spacer(minLength: Space.sm)
            // While running, the last run's status would read as this one's.
            Text(session.query.isCancelling ? "Cancelling…" : session.query.isRunning ? "Running…" : session.query.status)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
        .frame(minHeight: 32)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func errorBar(_ error: DatabaseError) -> some View {
        Button {
            session.revealErrorLine()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Image(systemName: StatusStyle.errorSymbol)
                    .foregroundStyle(StatusStyle.error)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Text(session.query.errorLine.map { "Line \($0): " } ?? "").fontWeight(.semibold))\(error.message)")
                    if let suggestion = error.suggestion {
                        Text(suggestion).foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(StatusStyle.error.opacity(0.10))
        .help("Move the cursor to the line with the error")
        .accessibilityLabel("Error on line \(session.query.errorLine ?? 0): \(error.message)")
    }

    @ViewBuilder
    private var results: some View {
        if session.query.results.columns.isEmpty {
            ContentUnavailableView("No Results", systemImage: "tablecells",
                                   description: Text("Run a query to see its results here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let editing = DataGrid.Editing(
                canEdit: { session.canEditQueryCell(row: $0, column: $1) && !session.queryCellOpensEditor(row: $0, column: $1) },
                text: { session.query.results.rows[$0][$1].plainText ?? "" },
                save: { session.editQueryCell(row: $0, column: $1, to: $2) })
            DataGrid(data: session.query.results, editing: editing, insertTable: DataGrid.InsertTarget(table: session.query.resultTable, engine: session.engine),
                     exportResults: session.requestExportResults,
                     fieldEditor: DataGrid.FieldEditorHook(opens: { session.queryCellOpensEditor(row: $0, column: $1) },
                                                           open: { session.openQueryValue(row: $0, column: $1, typed: $2) }),
                     accessibilityLabel: "Query results")
                .opacity(session.query.isRunning ? 0.5 : 1)
        }
    }
}
