import QuarryKit
import SwiftUI

/// Save Query… (S-034, ⌃⇧⌘S): a name, the part of the editor to keep, and a
/// preview. Return saves (or replaces a saved query with the same name); Escape cancels.
struct SaveQuerySheet: View {
    @Bindable var draft: SaveQueryDraft
    let save: () -> Void
    let close: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("Required"))
                        .focused($nameFocused)
                        .onSubmit { if draft.canSave { save() } }
                        .help("Shown in Query > Saved Queries")
                    if draft.offersChoice {
                        Picker("Save", selection: $draft.part) {
                            Text("Current Statement").tag(SaveQueryDraft.Part.statement)
                            Text("Whole Editor").tag(SaveQueryDraft.Part.editor)
                        }
                        .pickerStyle(.segmented)
                        .help("The selection or the statement ⌘R runs, or everything in the editor")
                    }
                } header: {
                    Text("Save Query")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                }
                Section {
                    ScrollView {
                        Text(draft.text)
                            .font(.system(size: DataStyle.editorSize, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: Layout.saveQueryPreviewHeight)
                    .accessibilityLabel("Query to save")
                } footer: {
                    Text(draft.replaces ? "Replaces the saved query with this name." : "Saved queries are on this Mac, for every server.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .fitsContent()
            HStack(spacing: Space.sm) {
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button(draft.replaces ? "Replace" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.canSave)
                    .help(draft.replaces ? "Replace the saved query with this name (Return)" : "Save the query (Return)")
            }
            .gridProbe("buttons", area: "save-query")
            .padding([.horizontal, .bottom], Space.margin)
        }
        .frame(width: Layout.newDatabaseWidth)
        .gridArea("save-query")
        .onAppear { nameFocused = true }
    }
}
