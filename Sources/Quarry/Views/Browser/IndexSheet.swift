import QuarryKit
import QuarryControllers
import SwiftUI

/// Add Index (S-024): the type, name, fields with their prefixes, and the
/// advanced options. Add (Return) runs one ALTER TABLE; an error shows here
/// and the sheet stays open.
struct IndexSheet: View {
    @Bindable var draft: IndexDraft
    let save: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Type", selection: $draft.kind) {
                        ForEach(draft.kinds, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                                .selectionDisabled(kind == .primary && draft.hasPrimaryKey)
                        }
                    }
                    .help(draft.hasPrimaryKey ? "What the index does. The table has a primary key already"
                          : "What the index does: Unique refuses repeated values")
                    TextField("Name", text: $draft.shownName, prompt: Text("Automatic"))
                        .disabled(draft.kind == .primary)
                        .onSubmit { if draft.canSave { save() } }
                        .help(draft.kind == .primary ? "A primary key is always named PRIMARY"
                              : draft.isSQLite ? "Leave empty to name the index after its table and fields"
                              : "Leave empty to name the index after its first field")
                    if let problem = draft.nameProblem {
                        Label(problem, systemImage: StatusStyle.warningSymbol)
                            .foregroundStyle(StatusStyle.warning)
                            .font(.callout)
                            .accessibilityLabel("Error: \(problem)")
                    }
                } header: {
                    Text(draft.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                }
                Section("Fields") {
                    ForEach(Array(draft.parts.enumerated()), id: \.element.id) { offset, part in
                        partRow(part, number: offset + 1)
                    }
                    HStack {
                        Button("Add Field to Index", systemImage: "plus") { draft.addPart() }
                            .disabled(!draft.canAddPart)
                            .help("Add the next field to the index")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                }
                if !draft.isSQLite {
                Section("Advanced", isExpanded: $draft.showsAdvanced) {
                    Picker("Storage Type", selection: $draft.storage) {
                        ForEach(IndexStorage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .disabled(!draft.kind.takesStorage)
                    .help("BTREE suits ranges and sorting; HASH only exact matches, on engines that have it")
                    TextField("Key Block Size", text: $draft.keyBlockSize, prompt: Text("Default"))
                        .help("The size in kilobytes of the index’s pages, a hint the engine may ignore")
                    TextField("Comment", text: $draft.comment, prompt: Text("None"))
                }
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
                    Section {
                        Label {
                            Text(error.message).textSelection(.enabled)
                        } icon: {
                            Image(systemName: StatusStyle.errorSymbol).foregroundStyle(StatusStyle.error)
                        }
                        .accessibilityLabel("Error: \(error.message)")
                    }
                }
            }
            .formStyle(.grouped)
            .fitsContent()
            .disabled(draft.isSaving)
            buttons
                .gridProbe("buttons", area: "index-sheet")
                .padding([.horizontal, .bottom], Space.margin)
        }
        .frame(width: Layout.indexSheetWidth)
        .gridArea("index-sheet")
    }

    /// One field of the index: its menu, its prefix, and −.
    private func partRow(_ part: IndexDraft.Part, number: Int) -> some View {
        let binding = Binding(get: { draft.parts.first { $0.id == part.id } ?? part },
                              set: { new in
                                  if let at = draft.parts.firstIndex(where: { $0.id == part.id }) { draft.parts[at] = new }
                              })
        let rule = draft.rule(for: part)
        return LabeledContent("Field \(number)") {
            HStack(spacing: Space.sm) {
                Picker("Field \(number)", selection: binding.field) {
                    ForEach(draft.fields, id: \.name) { field in
                        Text("\(field.name)  \(field.type.uppercased())").tag(field.name)
                    }
                }
                .labelsHidden()
                .help("A field the index holds, in order")
                if !draft.isSQLite {
                    TextField("Prefix for field \(number)", text: binding.prefix, prompt: Text(draft.prefixPrompt(for: part)))
                        .labelsHidden()
                        .frame(width: Layout.prefixFieldWidth)
                        .disabled(rule == .none)
                        .help(rule == .required ? "Text and Blob fields need a prefix: how many characters or bytes to index"
                              : rule == .optional ? "Index only the first characters or bytes, to keep the index small"
                              : "This field is indexed whole")
                }
                Button("Remove Field from Index", systemImage: "minus") { draft.removePart(part.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!draft.canRemovePart)
                    .help("Take this field out of the index")
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            if draft.isSaving {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Adding index")
            }
            Spacer()
            Button("Cancel", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
            Button("Add", action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.canSave)
                .help("Add the index to the table (Return)")
        }
    }
}
