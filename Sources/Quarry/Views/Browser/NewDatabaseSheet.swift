import QuarryKit
import QuarryControllers
import SwiftUI

/// New Database (S-018): a name, a character set and a collation. The
/// collation menu lists only the chosen character set's collations. Create
/// (Return) selects the new database; Escape cancels. The Name field takes
/// focus on open: typing a name is the sheet's job.
struct NewDatabaseSheet: View {
    @Bindable var creator: DatabaseCreator
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
                        .help("The new database’s name, up to 64 characters")
                    if let problem = creator.nameProblem {
                        Label(problem, systemImage: StatusStyle.warningSymbol)
                            .foregroundStyle(StatusStyle.warning)
                            .font(.callout)
                            .accessibilityLabel("Error: \(problem)")
                    }
                    CharsetMenus(catalog: creator.catalog, charset: $creator.charset, collation: $creator.collation,
                                 defaultCharsetTitle: creator.defaultCharsetTitle,
                                 defaultCollationTitle: creator.defaultCollationTitle, collations: creator.collations)
                } header: {
                    Text("New Database")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
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
            // The grouped Form insets its own sections; the buttons line up with them.
            buttons
                .gridProbe("buttons", area: "new-database")
                .padding([.horizontal, .bottom], Space.margin)
        }
        .frame(width: Layout.newDatabaseWidth)
        .gridArea("new-database")
        .onAppear { nameFocused = true }
    }

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            if creator.catalog == nil, creator.loadError == nil {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Loading character sets")
            }
            Spacer()
            Button("Cancel", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
            Button("Create", action: create)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!creator.canCreate)
                .help("Create the database and open it (Return)")
        }
    }
}

/// Character Set and Collation menus for New Database and Change Character Set.
/// The collation menu lists only the chosen character set's collations; nil
/// in either is the default row.
struct CharsetMenus: View {
    let catalog: CharsetCatalog?
    @Binding var charset: String?
    @Binding var collation: String?
    /// "Server Default (utf8mb4)"; nil leaves the row out, when a character set must be chosen.
    let defaultCharsetTitle: String?
    let defaultCollationTitle: String
    let collations: [String]

    var body: some View {
        Picker("Character Set", selection: $charset) {
            if let defaultCharsetTitle {
                Text(defaultCharsetTitle).tag(String?.none)
            }
            if let catalog {
                if defaultCharsetTitle != nil { Divider() }
                ForEach(Array(catalog.charsets.enumerated()), id: \.element.name) { index, charset in
                    if index == catalog.utf8Count, index > 0 { Divider() }
                    Text(charset.title).tag(String?.some(charset.name))
                }
            } else if defaultCharsetTitle == nil {
                Text("Loading…").tag(String?.none)
            }
        }
        .disabled(catalog == nil)
        .help("How text is stored. UTF-8 (utf8mb4) holds every language and emoji")

        Picker("Collation", selection: $collation) {
            Text(defaultCollationTitle).tag(String?.none)
            if !collations.isEmpty {
                Divider()
                ForEach(collations, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
        }
        .disabled(catalog == nil)
        .help("How text is compared and sorted. The list follows the character set")
    }
}
