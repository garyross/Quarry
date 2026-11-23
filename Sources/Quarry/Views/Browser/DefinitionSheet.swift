import QuarryKit
import QuarryControllers
import SwiftUI

/// New View…, New Procedure…, New Function… and their Edit sheets (S-030):
/// a name, the object's options and its SELECT or body in the SQL editor.
/// Create or Save (⌘Return) runs it; an error shows here and the sheet stays
/// filled in. An edited routine is dropped and created again, and its old
/// version comes back when the new one fails.
struct DefinitionSheet: View {
    @Bindable var draft: DefinitionDraft
    let save: () -> Void
    let close: () -> Void
    @State private var cursor = 0
    @State private var selectRequest: NSRange?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("Required"))
                        .focused($nameFocused)
                        .help(draft.kind == .view ? "Views share their names with tables" : "The \(draft.noun)’s name, up to 64 characters")
                    if let problem = draft.nameProblem {
                        Label(problem, systemImage: StatusStyle.warningSymbol)
                            .foregroundStyle(StatusStyle.warning)
                            .font(.callout)
                            .accessibilityLabel("Error: \(problem)")
                    }
                    if draft.kind == .view { if !draft.isSQLite { viewOptions } } else { routineOptions }
                } header: {
                    Text(draft.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                }
                Section {
                    SQLEditor(text: $draft.text, cursor: $cursor, selectRequest: $selectRequest,
                              marksStatement: false, accessibilityLabel: editorLabel)
                        .frame(height: draft.isRoutine ? Layout.triggerEditorHeight : Layout.definitionEditorHeight)
                        .help(editorHelp)
                } header: {
                    Text(editorLabel)
                } footer: {
                    Text(SQLText.highlighted(draft.statement))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .accessibilityLabel("Runs: \(draft.statement)")
                }
                if let error = draft.error {
                    Section { ErrorMessage(error: error) }
                }
            }
            .formStyle(.grouped)
            .fitsContent(max: Layout.definitionSheetMaxHeight)
            .disabled(draft.isSaving || draft.isLoading)
            buttons
                .gridProbe("buttons", area: "definition-sheet")
                .padding([.horizontal, .bottom], Space.margin)
        }
        .frame(width: Layout.definitionSheetWidth)
        .gridArea("definition-sheet")
        .onAppear { if !draft.isEdit { nameFocused = true } }
    }

    private var editorLabel: String { draft.kind == .view ? "SELECT Statement" : "Body" }

    private var editorHelp: String {
        switch draft.kind {
        case .view: "The query the view shows, one SELECT"
        case .function: "One statement, or several between BEGIN and END; RETURN gives the value"
        default: "One statement, or several between BEGIN and END"
        }
    }

    @ViewBuilder
    private var viewOptions: some View {
        Picker("Algorithm", selection: $draft.algorithm) {
            ForEach(ViewAlgorithm.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .help("Merge folds the view into each query; Temporary Table runs it first. Undefined lets the server choose")
        securityPicker
        Picker("Check Option", selection: $draft.checkOption) {
            ForEach(ViewCheckOption.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .help("Refuse inserts and updates through the view that its WHERE clause wouldn’t show")
    }

    @ViewBuilder
    private var routineOptions: some View {
        TextField(text: $draft.parameters, prompt: Text(draft.kind == .function ? "amount DECIMAL(10,2)" : "IN id INT, OUT total INT")) {
            Text("Parameters").font(.body)
        }
            .font(.system(.body, design: .monospaced))
            .help(draft.kind == .function ? "Name and type of each parameter, separated by commas"
                  : "IN, OUT or INOUT, a name and a type for each parameter, separated by commas")
        if draft.kind == .function {
            TextField(text: $draft.returns, prompt: Text("Required")) {
                Text("Returns").font(.body)
            }
                .font(.system(.body, design: .monospaced))
                .help("The type of the value the function returns, like INT or VARCHAR(255)")
        }
        Picker("Data Access", selection: $draft.dataAccess) {
            ForEach(RoutineDataAccess.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .help("What the body does with data. The server trusts this; it doesn’t check it")
        securityPicker
        Toggle("Deterministic", isOn: $draft.deterministic)
            .help("The same arguments always give the same result. Binary logging asks functions for this")
        TextField("Comment", text: $draft.comment)
    }

    private var securityPicker: some View {
        Picker("Security", selection: $draft.security) {
            ForEach(SQLSecurity.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .help("Run with the privileges of the definer, or of the user who calls it")
    }

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            if draft.isSaving || draft.isLoading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(draft.isLoading ? "Loading the definition" : "Saving \(draft.noun)")
            }
            Spacer()
            Button("Cancel", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
            // ⌘Return: Return types a new line in the editor.
            Button(draft.saveTitle, action: save)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.canSave)
                .help(draft.isEdit ? "Replace the \(draft.noun) with this one (⌘Return)" : "Create the \(draft.noun) (⌘Return)")
        }
    }
}
