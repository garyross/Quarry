import QuarryKit
import QuarryControllers
import SwiftUI

/// Duplicate Table (S-022): a new name, filled in as "orders_copy", and
/// whether the rows come too. Return duplicates; Escape cancels.
struct DuplicateTableSheet: View {
    @Bindable var duplicator: TableDuplicator
    let run: () -> Void
    let close: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    LabeledContent("Source") {
                        Text(duplicator.source).textSelection(.enabled)
                    }
                    TextField("New Name", text: $duplicator.name, prompt: Text("Required"))
                        .focused($nameFocused)
                        .disabled(duplicator.isWorking)
                        .onSubmit { if duplicator.canRun { run() } }
                        .help("The copy’s name, up to 64 characters")
                    if let problem = duplicator.nameProblem {
                        Label(problem, systemImage: StatusStyle.warningSymbol)
                            .foregroundStyle(StatusStyle.warning)
                            .font(.callout)
                            .accessibilityLabel("Error: \(problem)")
                    }
                    Toggle("Copy table rows", isOn: $duplicator.withRows)
                        .disabled(duplicator.isWorking)
                        .help("Off: the copy has the same fields and indexes, with no rows")
                } header: {
                    Text("Duplicate Table")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("Triggers aren’t copied.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let error = duplicator.error {
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
                .gridProbe("buttons", area: "duplicate-table")
                .padding([.horizontal, .bottom], Space.margin)
        }
        .frame(width: Layout.newDatabaseWidth)
        .gridArea("duplicate-table")
        .onAppear { nameFocused = true }
    }

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            if duplicator.isWorking {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Copying \(duplicator.source)")
            }
            Spacer()
            Button("Cancel", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
                .disabled(duplicator.isWorking)
            Button("Duplicate", action: run)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!duplicator.canRun)
                .help("Copy the table and open the copy (Return)")
        }
    }
}
