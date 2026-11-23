import QuarryKit
import QuarryControllers
import SwiftUI

/// Info (⌘5): a table's options, sizes, dates and create statement (S-027).
/// Engine, Character Set, Collation, Auto Increment and Comment change the
/// table at once, one ALTER TABLE each, as Sequel Pro's Table Info did.
struct InfoView: View {
    @Environment(Session.self) private var session
    @FocusState private var focus: Field?

    private enum Field { case autoIncrement, comment }

    var body: some View {
        let info = session.info
        Form {
            if let error = info.editError ?? info.load.error {
                Section { ErrorMessage(error: error) }
            }
            if let note = info.rowNote {
                Section {
                    Label(note, systemImage: "number")
                        .foregroundStyle(.secondary)
                        .help("Content edits and deletes find each row by its rowid, since the table has no primary key")
                }
            }
            if info.kind == .table, let options = info.sqliteOptions {
                Section("Table") {
                    LabeledContent("Options", value: options.isEmpty ? "None" : options.joined(separator: ", "))
                        .help("STRICT tables refuse values of the wrong type; WITHOUT ROWID tables are stored by their primary key")
                }
            } else if info.kind == .table, info.status != nil {
                options(info)
            } else if let kind = info.kind {
                Section("Details") {
                    LabeledContent("Kind", value: kind.rawValue.capitalized)
                    // S-030: views and routines change in the definition sheet.
                    if kind != .table, let shown = session.selectedObject, shown.kind == kind,
                       let object = session.objectActions([shown.id]).definition {
                        LabeledContent("Definition") {
                            Button(ObjectActions.editDefinitionTitle(object)) { session.requestEditDefinition([object.id]) }
                                .help("Change the \(CreateScript.noun(kind))’s definition (⌃⌥⌘E)")
                        }
                    }
                }
            }
            details("Size", info.sizeDetails)
            details("Dates", info.dateDetails)
            Section("Create Statement") {
                ScrollView(.horizontal) {
                    Text(SQLText.highlighted(info.createStatement))
                        .font(.system(size: DataStyle.editorSize, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("Create statement")
            }
        }
        .formStyle(.grouped)
        .opacity(info.load.isLoading ? 0.5 : 1)
        .onChange(of: focus) { old, _ in
            if old == .comment { session.commitTableComment() }
            if old == .autoIncrement { session.commitAutoIncrement() }
        }
        .alert(engineTitle(info), isPresented: Binding(get: { info.pendingEngine != nil },
                                                       set: { if !$0 { info.pendingEngine = nil } })) {
            Button("Change Engine") { session.confirmTableEngine() }
            Button("Cancel", role: .cancel) { info.pendingEngine = nil }
        } message: {
            Text("The server copies every row into a new table, which can take a while for a big table.")
        }
    }

    @ViewBuilder
    private func options(_ info: InfoController) -> some View {
        @Bindable var info = info
        Section {
            Picker("Engine", selection: Binding(get: { info.status?.engine ?? "" },
                                                set: { session.requestTableEngine($0) })) {
                ForEach(info.engineChoices, id: \.self) { Text($0).tag($0) }
            }
            .help("How the server stores this table; changing it rebuilds the table")
            Picker("Character Set", selection: Binding(get: { info.charset }, set: { session.setTableCharset($0) })) {
                ForEach(info.charsetChoices, id: \.self) { name in
                    Text(charsetTitle(name, info)).tag(name)
                }
            }
            .help("The default for new text fields; existing fields keep theirs")
            Picker("Collation", selection: Binding(get: { info.status?.collation ?? "" },
                                                   set: { session.setTableCollation($0) })) {
                ForEach(info.collationChoices, id: \.self) { Text($0).tag($0) }
            }
            .help("How new text fields sort and compare by default")
            if info.status?.autoIncrement != nil {
                LabeledContent("Auto Increment") {
                    HStack(spacing: Space.sm) {
                        TextField("Auto Increment", text: $info.autoIncrementText)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .focused($focus, equals: .autoIncrement)
                            .onSubmit { session.commitAutoIncrement() }
                            .help("The value the next new row gets; press Return to set it")
                        Button("Reset") { session.resetAutoIncrement() }
                            .disabled(!info.canResetAutoIncrement)
                            .help("Start again just after the highest value in use (⌃⌥⌘R)")
                    }
                }
            }
            TextField("Comment", text: $info.comment, prompt: Text("None"))
                .focused($focus, equals: .comment)
                .onSubmit { session.commitTableComment() }
                .help("A note stored with the table; press Return to save it")
        } header: {
            HStack(spacing: Space.sm) {
                Text("Table")
                if info.isChanging { ProgressView().controlSize(.small) }
            }
        }
        .disabled(!info.canEdit)
    }

    @ViewBuilder
    private func details(_ title: String, _ rows: [(label: String, value: String)]) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows, id: \.label) { row in
                    LabeledContent(row.label) {
                        Text(row.value).textSelection(.enabled).monospacedDigit()
                    }
                }
            }
        }
    }

    private func charsetTitle(_ name: String, _ info: InfoController) -> String {
        guard let description = info.catalog?.charset(named: name)?.description, !description.isEmpty else { return name }
        return "\(name) (\(description))"
    }

    private func engineTitle(_ info: InfoController) -> String {
        "Change the engine of “\(info.tableName)” to \(info.pendingEngine ?? "")?"
    }
}
