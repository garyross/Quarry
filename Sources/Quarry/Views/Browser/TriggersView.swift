import QuarryKit
import QuarryControllers
import SwiftUI

/// Triggers (⌘4): the table's triggers; add or edit one in a sheet, delete the selected ones (S-026).
struct TriggersView: View {
    @Environment(Session.self) private var session

    var body: some View {
        let triggers = session.triggers
        grid(triggers)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let error = triggers.editError {
                        EditErrorBar(error: error) { triggers.editError = nil }
                    }
                    statusBar(triggers)
                }
            }
            .alert(TriggersController.deleteTitle(triggers.pendingDelete ?? []),
                   isPresented: Binding(get: { triggers.pendingDelete != nil },
                                        set: { if !$0 { triggers.pendingDelete = nil } })) {
                Button("Delete", role: .destructive) { session.confirmDeleteTriggers() }
                Button("Cancel", role: .cancel) { triggers.pendingDelete = nil }
            } message: {
                Text("The table and its rows stay. This can\u{2019}t be undone.")
            }
            .sheet(item: Binding(get: { triggers.sheet }, set: { triggers.sheet = $0 })) { draft in
                TriggerSheet(draft: draft, save: { session.saveTriggerSheet() }, close: { triggers.sheet = nil })
                    .noInitialFocus()
            }
    }

    private func grid(_ triggers: TriggersController) -> GridPane {
        let session = session
        let reports = DataGrid.Reports(selection: { triggers.selection = $0 }, focus: { triggers.gridHasFocus = $0 })
        let actions = DataGrid.RowActions(canAdd: { triggers.canAdd }, canDuplicate: { false },
                                          canDelete: { triggers.canDelete },
                                          add: { session.requestAddTrigger() }, duplicate: {},
                                          delete: { session.requestDeleteTriggers() },
                                          noun: "Trigger", addsWithSheet: true,
                                          edit: { session.requestEditTrigger(row: $0) }, duplicates: false)
        let emptyAction: (title: String, action: () -> Void)? = triggers.canAdd
            ? ("Add Trigger", { session.requestAddTrigger() }) : nil
        return GridPane(data: triggers.grid, load: triggers.load, emptyTitle: "No Triggers", emptySymbol: "bolt",
                        rowActions: actions, reports: reports,
                        selectRequest: triggers.selectRequest.map { ($0.row, $0.id) }, emptyAction: emptyAction)
    }

    private func statusBar(_ triggers: TriggersController) -> some View {
        StatusBar(text: StatementResult.formatCount(triggers.grid.rows.count, "trigger"),
                  isLoading: triggers.load.isLoading || triggers.isChanging, leading: {
            HStack(spacing: Space.xs) {
                Button("Add Trigger", systemImage: "plus") { session.requestAddTrigger() }
                    .disabled(!triggers.canAdd)
                    .help("Run a statement on each row the table inserts, updates or deletes (⌥⌘A)")
                Button("Delete Trigger", systemImage: "minus") { session.requestDeleteTriggers() }
                    .disabled(!triggers.canDelete)
                    .help("Delete the selected triggers (⌘⌫)")
                Button("Edit Trigger", systemImage: "pencil") { session.requestEditTrigger() }
                    .disabled(!triggers.canEdit)
                    .help("Change the selected trigger (⌥⌘E)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            Divider().frame(height: Space.md)
        }, trailing: { EmptyView() })
    }
}

/// Add Trigger and Edit Trigger (S-026): a name, Action Time, Event, and the
/// statement run for each row. Add or Save (⌘Return) runs it; an error shows
/// here, the sheet stays filled in, and an edited trigger keeps its old version.
struct TriggerSheet: View {
    @Bindable var draft: TriggerDraft
    let save: () -> Void
    let close: () -> Void
    @State private var cursor = 0
    @State private var selectRequest: NSRange?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .help("Trigger names are unique in the database")
                    if let problem = draft.nameProblem {
                        problemLabel(problem)
                    }
                    Picker("Action Time", selection: $draft.timing) {
                        ForEach(TriggerTiming.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Run before the row is written (and change NEW values), or after")
                    Picker("Event", selection: $draft.event) {
                        ForEach(TriggerEvent.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("The change that runs the trigger")
                } header: {
                    Text(draft.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                }
                Section {
                    SQLEditor(text: $draft.statement, cursor: $cursor, selectRequest: $selectRequest,
                              marksStatement: false, accessibilityLabel: "Statement")
                        .frame(height: Layout.triggerEditorHeight)
                        .help("One statement, or several between BEGIN and END. NEW and OLD name the row")
                } header: {
                    Text(draft.header)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .accessibilityLabel("Statement, after \(draft.header)")
                }
                if let error = draft.error {
                    Section { ErrorMessage(error: error) }
                }
            }
            .formStyle(.grouped)
            .fitsContent()
            .disabled(draft.isSaving)
            buttons
                .gridProbe("buttons", area: "trigger-sheet")
                .padding([.horizontal, .bottom], Space.margin)
        }
        .frame(width: Layout.triggerSheetWidth)
        .gridArea("trigger-sheet")
    }

    private func problemLabel(_ problem: String) -> some View {
        Label(problem, systemImage: StatusStyle.warningSymbol)
            .foregroundStyle(StatusStyle.warning)
            .font(.callout)
            .accessibilityLabel("Error: \(problem)")
    }

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            if draft.isSaving {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(draft.isEdit ? "Saving trigger" : "Adding trigger")
            }
            Spacer()
            Button("Cancel", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
            // ⌘Return: Return types a new line in the statement.
            Button(draft.saveTitle, action: save)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.canSave)
                .help(draft.isEdit ? "Replace the trigger with this one (⌘Return)" : "Add the trigger to the table (⌘Return)")
        }
    }
}
