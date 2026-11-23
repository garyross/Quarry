import QuarryKit
import QuarryControllers
import SwiftUI

/// Add Foreign Key (S-025): a field, the table and field it references, what
/// happens on update and delete, and an optional name. Add (Return) runs one
/// ALTER TABLE; an error shows here and the sheet stays open.
struct ForeignKeySheet: View {
    @Bindable var draft: ForeignKeyDraft
    let tableChanged: () -> Void
    let save: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("Automatic"))
                        .onSubmit { if draft.canSave { save() } }
                        .help("Leave empty to let the server name the foreign key")
                    if let problem = draft.nameProblem {
                        problemLabel(problem)
                    }
                    Picker("Field", selection: $draft.field) {
                        ForEach(draft.fields, id: \.name) { field in
                            Text("\(field.name)  \(typeText(field))").tag(field.name)
                        }
                    }
                    .help("The field in “\(draft.table)” whose values must exist in the other table")
                } header: {
                    Text(draft.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                }
                Section("References") {
                    LabeledContent("Table") {
                        HStack(spacing: Space.sm) {
                            if draft.isLoadingReference {
                                ProgressView().controlSize(.small)
                                    .accessibilityLabel("Loading the table’s fields")
                            }
                            Picker("Table", selection: $draft.referencedTable) {
                                ForEach(draft.tables, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: draft.referencedTable) { tableChanged() }
                            .help("A table in this database that uses InnoDB")
                        }
                    }
                    Picker("Referenced Field", selection: $draft.referencedField) {
                        if draft.candidates.isEmpty { Text("None").tag("") }
                        ForEach(draft.candidates, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(draft.candidates.isEmpty)
                    .help("Only fields of the same type that lead an index are listed")
                    if let problem = draft.referenceProblem {
                        problemLabel(problem)
                    }
                }
                Section("Actions") {
                    actionPicker("On Update", selection: $draft.onUpdate,
                                 help: "What happens to these rows when the referenced value changes")
                    actionPicker("On Delete", selection: $draft.onDelete,
                                 help: "What happens to these rows when the referenced row is deleted")
                }
                Section {
                } footer: {
                    Text(draft.sql)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .accessibilityLabel("Statement: \(draft.sql)")
                }
                if let error = draft.error {
                    Section { ErrorMessage(error: error) }
                }
            }
            .formStyle(.grouped)
            .fitsContent()
            .disabled(draft.isSaving)
            buttons
                .gridProbe("buttons", area: "foreign-key-sheet")
                .padding([.horizontal, .bottom], Space.margin)
        }
        .frame(width: Layout.indexSheetWidth)
        .gridArea("foreign-key-sheet")
    }

    private func typeText(_ field: FieldDefinition) -> String {
        let length = field.length.isEmpty || field.family == .integer ? "" : "(\(field.length))"
        return (field.type + length + (field.isUnsigned ? " unsigned" : "")).uppercased()
    }

    private func actionPicker(_ title: String, selection: Binding<ForeignKeyAction>, help: String) -> some View {
        Picker(title, selection: selection) {
            ForEach(ForeignKeyAction.allCases, id: \.self) { action in
                Text(action.title).tag(action)
                    .selectionDisabled(action == .setNull && !draft.nullAllowed)
            }
        }
        .help(draft.nullAllowed ? help : help + ". Set NULL needs a field that allows NULL")
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
                    .accessibilityLabel("Adding foreign key")
            }
            Spacer()
            Button("Cancel", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
            Button("Add", action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.canSave)
                .help("Add the foreign key to the table (Return)")
        }
    }
}
