import QuarryKit
import QuarryControllers
import SwiftUI

/// Duplicate Database, Rename Database and Change Character Set (S-019).
/// Return runs it, Escape cancels; while it runs, a progress line names each
/// object. Problems keep the sheet open with a list and a Done button.
struct DatabaseEditorSheet: View {
    @Bindable var editor: DatabaseEditor
    let run: () -> Void
    let close: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    fields
                } header: {
                    Text(editor.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                }
                if let error = editor.error {
                    Section {
                        Label {
                            Text(error.message).textSelection(.enabled)
                        } icon: {
                            Image(systemName: StatusStyle.errorSymbol).foregroundStyle(StatusStyle.error)
                        }
                        .accessibilityLabel("Error: \(error.message)")
                    }
                }
                if editor.isFinished {
                    Section {
                        ForEach(editor.problems, id: \.self) { problem in
                            Label {
                                Text(problem).textSelection(.enabled)
                            } icon: {
                                Image(systemName: StatusStyle.warningSymbol).foregroundStyle(StatusStyle.warning)
                            }
                            .accessibilityLabel("Problem: \(problem)")
                        }
                    } header: {
                        Text(editor.mode == .rename ? "Renamed, with problems" : "Duplicated, with problems")
                    }
                }
            }
            .formStyle(.grouped)
            .fitsContent()
            buttons
                .gridProbe("buttons", area: "database-editor")
                .padding([.horizontal, .bottom], Space.margin)
        }
        .frame(width: Layout.newDatabaseWidth)
        .gridArea("database-editor")
        .onAppear { if editor.mode != .alter { nameFocused = true } }
    }

    @ViewBuilder private var fields: some View {
        LabeledContent(editor.mode == .alter ? "Database" : "Source") {
            Text(editor.source).textSelection(.enabled)
        }
        switch editor.mode {
        case .duplicate, .rename:
            TextField("New Name", text: $editor.name, prompt: Text("Required"))
                .focused($nameFocused)
                .disabled(editor.isWorking || editor.isFinished)
                .onSubmit { if editor.canRun { run() } }
                .help("The database’s new name, up to 64 characters")
            if let problem = editor.nameProblem {
                Label(problem, systemImage: StatusStyle.warningSymbol)
                    .foregroundStyle(StatusStyle.warning)
                    .font(.callout)
                    .accessibilityLabel("Error: \(problem)")
            }
            if editor.mode == .duplicate {
                Toggle("Copy table rows", isOn: $editor.withRows)
                    .disabled(editor.isWorking || editor.isFinished)
                    .help("Off: the copy has the same tables, views and routines, with no rows")
            } else {
                Text("Every table, view, trigger, routine and event moves to the new name.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .alter:
            CharsetMenus(catalog: editor.catalog, charset: $editor.charset, collation: $editor.collation,
                         defaultCharsetTitle: nil, defaultCollationTitle: editor.defaultCollationTitle,
                         collations: editor.collations)
                .disabled(editor.isWorking)
            Text("New tables get these. Existing tables and fields keep theirs.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            if let text = editor.progressText {
                ProgressView().controlSize(.small)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.updatesFrequently)
            } else if editor.mode == .alter, editor.catalog == nil, editor.error == nil {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Loading character sets")
            }
            Spacer()
            if editor.isFinished {
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(editor.isWorking)
                Button(editor.actionTitle, action: run)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!editor.canRun)
                    .help(help)
            }
        }
    }

    private var help: String {
        switch editor.mode {
        case .duplicate: "Copy the database under the new name and open the copy (Return)"
        case .rename: "Move everything to the new name and open it (Return)"
        case .alter: "Set the database’s default character set and collation (Return)"
        }
    }
}
