import QuarryKit
import SwiftUI

/// Save Connection File… (⌘S) and Save Session… (⇧⌘S), S-055: what goes in
/// the file, then a save panel. Passwords go in only with a file password,
/// and are then encrypted with it.
struct ConnectionFileSheet: View {
    @Bindable var draft: ConnectionFileDraft
    let save: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    LabeledContent(draft.asSession ? "Saves" : "Connection", value: draft.summary)
                    Toggle("Connect when opened", isOn: $draft.options.connectsOnOpen)
                        .help("Opening the file connects at once, instead of filling in the Connect page")
                    Toggle("Database, table and view", isOn: $draft.options.includesPlace)
                        .help("Opening the file returns to the same database, table and view")
                    Toggle("Query editor text", isOn: $draft.options.includesQuery)
                        .help("The text in Query comes back when the file is opened")
                } header: {
                    Text(draft.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                }
                Section {
                    Toggle("Include passwords", isOn: $draft.options.includesPasswords)
                        .help("Save the MySQL and SSH passwords, encrypted with a file password")
                    if draft.options.includesPasswords {
                        SecureField("File Password", text: $draft.password, prompt: Text("Required"))
                            .help("Needed to open the file. Quarry can’t recover it if it’s lost.")
                        SecureField("Confirm", text: $draft.confirmation, prompt: Text("Type it again"))
                    }
                } footer: {
                    Text(draft.options.includesPasswords
                         ? "The file is encrypted. Sequel Pro can’t open an encrypted Quarry file."
                         : "Without passwords, Sequel Pro can open the file too. Quarry asks for the password when it connects.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .fitsContent()
            HStack(spacing: Space.sm) {
                if let problem = draft.problem, !draft.password.isEmpty || !draft.confirmation.isEmpty {
                    Label(problem, systemImage: StatusStyle.warningSymbol)
                        .font(.callout)
                        .foregroundStyle(StatusStyle.warning)
                        .accessibilityLabel("Error: \(problem)")
                }
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Save…", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.canSave)
                    .help("Choose where to save the file (Return)")
            }
            .gridProbe("buttons", area: "connection-file")
            .padding([.horizontal, .bottom], Space.margin)
        }
        .frame(width: Layout.connectionFileWidth)
        .gridArea("connection-file")
        .noInitialFocus()
    }
}

/// Open… on an encrypted connection or session file: its password.
struct FileUnlockSheet: View {
    @Bindable var unlock: FileUnlock
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    SecureField("File Password", text: $unlock.password, prompt: Text("Required"))
                        .onSubmit(open)
                    if let error = unlock.error {
                        Label(error, systemImage: StatusStyle.errorSymbol)
                            .font(.callout)
                            .foregroundStyle(StatusStyle.error)
                            .accessibilityLabel("Error: \(error)")
                    }
                } header: {
                    Text("“\(unlock.url.lastPathComponent)” Is Encrypted")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("Enter the password it was saved with, in Quarry or Sequel Pro.")
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
                Button("Open", action: open)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(unlock.password.isEmpty)
            }
            .gridProbe("buttons", area: "file-unlock")
            .padding([.horizontal, .bottom], Space.margin)
        }
        .frame(width: Layout.sshQuestionWidth)
        .gridArea("file-unlock")
    }
}
