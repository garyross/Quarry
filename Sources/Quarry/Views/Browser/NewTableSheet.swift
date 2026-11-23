import QuarryKit
import QuarryControllers
import SwiftUI

/// New Table (S-021): a name, an engine, a character set and a collation.
/// The table gets one field, `id`, and opens on Structure. Create (Return)
/// runs it; Escape cancels. The Name field takes focus on open.
struct NewTableSheet: View {
    @Bindable var creator: TableCreator
    let create: () -> Void
    let close: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $creator.name, prompt: Text("Required"))
                        .focused($nameFocused)
                        .onSubmit { if creator.canCreate { create() } }
                        .help("The new table’s name, up to 64 characters")
                    if let problem = creator.nameProblem {
                        Label(problem, systemImage: StatusStyle.warningSymbol)
                            .foregroundStyle(StatusStyle.warning)
                            .font(.callout)
                            .accessibilityLabel("Error: \(problem)")
                    }
                    if !creator.isSQLite {
                    Picker("Engine", selection: $creator.engine) {
                        Text(creator.defaultEngineTitle).tag(String?.none)
                        if let engines = creator.defaults?.engines, !engines.isEmpty {
                            Divider()
                            ForEach(engines, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    }
                    .disabled(creator.defaults == nil)
                    .help("How the server stores the table. InnoDB supports transactions and foreign keys")
                    CharsetMenus(catalog: creator.catalog, charset: $creator.charset, collation: $creator.collation,
                                 defaultCharsetTitle: creator.defaultCharsetTitle,
                                 defaultCollationTitle: creator.defaultCollationTitle, collations: creator.collations)
                    }
                } header: {
                    Text("New Table in \u{201C}\(creator.database)\u{201D}")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    Text(creator.isSQLite ? "The table starts with one field, id, an INTEGER primary key (its rowid). Add more in Structure."
                         : "The table starts with one field, id, an auto-increment primary key. Add more in Structure.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let error = creator.loadError ?? creator.createError {
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
                .gridProbe("buttons", area: "new-table")
                .padding([.horizontal, .bottom], Space.margin)
        }
        .frame(width: Layout.newDatabaseWidth)
        .gridArea("new-table")
        .onAppear { nameFocused = true }
    }

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            if creator.isLoading || creator.isCreating {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(creator.isCreating ? "Creating table" : "Loading engines and character sets")
            }
            Spacer()
            Button("Cancel", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
            Button("Create", action: create)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!creator.canCreate)
                .help("Create the table and open its Structure (Return)")
        }
    }
}
