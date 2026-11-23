import QuarryKit
import QuarryControllers
import SwiftUI

/// Add Field and Edit Field (S-023): every part of one field, and where it
/// goes. The type menu lists the types by family; choosing one clears the
/// options it can't have. Save (Return) runs its `TableChange`; an error shows
/// here and the sheet stays open.
struct FieldSheet: View {
    @Bindable var draft: FieldDraft
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
                        .help("The field’s name, up to 64 characters")
                    if let problem = draft.nameProblem {
                        Label(problem, systemImage: StatusStyle.warningSymbol)
                            .foregroundStyle(StatusStyle.warning)
                            .font(.callout)
                            .accessibilityLabel("Error: \(problem)")
                    }
                    if draft.isSQLite {
                        sqliteTypeField
                    } else {
                        typeMenu
                        TextField("Length", text: $draft.length, prompt: Text(draft.lengthPrompt))
                            .disabled(!draft.takesLength)
                            .help(lengthHelp)
                    }
                    if draft.family.isNumeric, !draft.isSQLite {
                        Toggle("Unsigned", isOn: $draft.isUnsigned)
                            .help("Only zero and positive numbers, which doubles the largest value")
                        Toggle("Zerofill", isOn: $draft.isZerofill)
                            .help("Pad numbers with zeros to the display width")
                    }
                    Toggle("Allow NULL", isOn: $draft.isNullable)
                        .help("Whether the field can hold NULL, no value")
                } header: {
                    Text(draft.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                }
                Section {
                    Picker("Default", selection: $draft.defaultKind) {
                        ForEach(draft.defaultKinds, id: \.self) { Text($0.title).tag($0) }
                    }
                    .help("What a new row gets when it doesn’t set this field")
                    if draft.defaultKind == .value {
                        TextField("Default Value", text: $draft.defaultText, prompt: Text("Empty text"))
                            .help(draft.isSQLite ? "Saved as typed; a call such as datetime('now'), or anything in parentheses, is kept as an expression"
                                  : "Saved as typed; CURRENT_TIMESTAMP and b'0101' are kept as expressions")
                    }
                    if draft.extras.count > 1 || !draft.isSQLite {
                        Picker("Extra", selection: $draft.extra) {
                            ForEach(draft.extras, id: \.self) { Text(draft.extraTitle($0)).tag($0) }
                        }
                        .help(draft.isSQLite ? "AUTOINCREMENT never gives out a number twice, even after rows are deleted"
                              : "auto_increment numbers new rows; it needs an index on the field")
                    }
                    if draft.isSQLite {
                        Picker("Collation", selection: $draft.collation) {
                            Text("Default").tag(String?.none)
                            ForEach(SQLiteTableChange.collations, id: \.self) { Text($0).tag(String?.some($0)) }
                            if let other = draft.collation, !SQLiteTableChange.collations.contains(other.uppercased()) {
                                Text(other).tag(String?.some(other))
                            }
                        }
                        .help("How text compares and sorts: NOCASE ignores the case of A to Z, RTRIM trailing spaces")
                    } else if draft.family.hasCollation {
                        CharsetMenus(catalog: draft.catalog, charset: $draft.charset, collation: $draft.collation,
                                     defaultCharsetTitle: "Table Default", defaultCollationTitle: "Default",
                                     collations: draft.collations)
                    }
                    if !draft.isSQLite {
                        TextField("Comment", text: $draft.comment, prompt: Text("None"))
                    }
                    Picker("Position", selection: $draft.position) {
                        ForEach(draft.positions, id: \.self) { Text($0.title).tag($0) }
                    }
                    .help("Where the field sits among the table’s fields")
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
            buttons
                .gridProbe("buttons", area: "field-sheet")
                .padding([.horizontal, .bottom], Space.margin)
        }
        .frame(width: Layout.fieldSheetWidth)
        .gridArea("field-sheet")
        .onAppear { nameFocused = draft.isAdding }
    }

    /// Every type by family, as Sequel Pro's type list; a type it doesn't list (uuid) on top.
    private var typeMenu: some View {
        Picker("Type", selection: $draft.type) {
            if let extra = draft.extraType {
                Text(extra.uppercased()).tag(extra)
                Divider()
            }
            ForEach(TypeFamily.allCases.filter { !$0.types.isEmpty }, id: \.self) { family in
                Section(family.title) {
                    ForEach(family.types, id: \.self) { Text($0.uppercased()).tag($0) }
                }
            }
        }
        .help("The kind of value the field holds. Options that don’t apply to it are cleared")
        .gridProbe("type-menu", area: "field-sheet", edge: "=type-menu<") // a locator for the snapshot, not a layout rule
    }

    /// SQLite (S-070): a STRICT table's types in a menu; otherwise any name, with SQLite's usual ones to pick from.
    @ViewBuilder private var sqliteTypeField: some View {
        let type = Binding(get: { draft.type.uppercased() }, set: { draft.type = $0 })
        if draft.isStrict {
            Picker("Type", selection: type) {
                ForEach(draft.sqliteTypes, id: \.self) { Text($0).tag($0) }
                if !draft.sqliteTypes.contains(type.wrappedValue) { Text(type.wrappedValue).tag(type.wrappedValue) }
            }
            .help("A STRICT table holds only these types")
        } else {
            LabeledContent("Type") {
                HStack(spacing: Space.xs) {
                    TextField("Type", text: type, prompt: Text("None"))
                        .labelsHidden()
                    Menu("Types") {
                        ForEach(draft.sqliteTypes, id: \.self) { name in Button(name) { draft.type = name } }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("SQLite's usual types")
                }
            }
            .help("Any name: SQLite stores INTEGER, REAL, TEXT and BLOB values, and the name decides which it prefers")
        }
    }

    private var lengthHelp: String {
        switch draft.family {
        case .list: "The allowed values, quoted and separated by commas"
        case .decimal: "Digits in all, then digits after the point: 10,2"
        case .time: "Digits of fractional seconds, 0 to 6"
        default: draft.takesLength ? "The size or display width" : "This type takes no length"
        }
    }

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            if draft.isSaving {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(draft.isAdding ? "Adding field" : "Saving field")
            }
            Spacer()
            Button("Cancel", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
            Button(draft.isAdding ? "Add" : "Save", action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.canSave)
                .help(draft.isAdding ? "Add the field to the table (Return)" : "Change the field (Return)")
        }
    }
}
