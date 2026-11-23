import QuarryKit
import SwiftUI

/// TCP/IP, socket or SSH details, centered in the detail column. Return connects.
struct ConnectForm: View {
    @Environment(AppModel.self) private var model
    @Environment(Session.self) private var session
    @FocusState private var focus: Field?

    enum Field: Hashable { case name, host, port, socket, user, password, database, sshHost, sshUser, sshPassword, sshKey, sshPort, sslKey, sslCertificate, sslCA, file }

    var body: some View {
        @Bindable var session = session
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Form {
                    Section {
                        TextField("Name", text: $session.form.name, prompt: Text("Optional"))
                            .focused($focus, equals: .name)
                    }
                    Section {
                        Picker("Connect With", selection: $session.form.transport) {
                            ForEach(ConnectionDetails.Transport.allCases) { transport in
                                Text(transport.title).tag(transport)
                            }
                        }
                        .pickerStyle(.segmented)
                        .help("Connect over the network (TCP/IP), through a socket file on this Mac, or through an SSH host, or open a SQLite file")
                        if session.form.transport == .sqlite {
                            SQLiteFields(form: $session.form, focus: $focus)
                        } else {
                            serverFields
                        }
                    }
                    if session.form.transport == .ssh {
                        SSHFields(form: $session.form, focus: $focus)
                    }
                    if session.form.transport != .sqlite {
                        SSLFields(form: $session.form, focus: $focus)
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
                .onSubmit { session.connect(model: model) }
                .disabled(session.phase == .connecting)

                feedback
                    .padding(.horizontal, Space.xl)

                buttons
                    .padding(.horizontal, Space.xl)
            }
            .frame(maxWidth: Layout.connectFormWidth)
            .padding(.vertical, Space.section)
            .frame(maxWidth: .infinity)
            .gridArea("connect", inset: 0)
        }
        .onChange(of: session.form) {
            session.connectProblem = nil
            session.testResult = nil
        }
    }

    /// Host, port or socket, user, password and database.
    @ViewBuilder
    private var serverFields: some View {
        @Bindable var session = session
                        if session.form.transport != .socket {
                            TextField(session.form.transport == .ssh ? "MySQL Host" : "Host", text: $session.form.host,
                                      prompt: Text(ConnectionDetails.defaultHost))
                                .focused($focus, equals: .host)
                                .help(session.form.transport == .ssh ? "The MySQL server as the SSH host sees it" : "")
                            TextField("Port", text: $session.form.port, prompt: Text(String(ConnectionDetails.defaultPort)))
                                .focused($focus, equals: .port)
                        } else {
                            TextField("Socket", text: $session.form.socket, prompt: Text(socketPrompt))
                                .focused($focus, equals: .socket)
                                .help("The server's socket file. Leave empty to use \(socketPrompt).")
                        }
                        TextField("User", text: $session.form.user)
                            .focused($focus, equals: .user)
                        SecureField("Password", text: $session.form.password)
                            .focused($focus, equals: .password)
                        TextField("Database", text: $session.form.database, prompt: Text("Optional"))
                            .focused($focus, equals: .database)
    }

    /// The socket Quarry uses when the field is empty: the first common one that exists.
    private var socketPrompt: String { ConnectionDetails.defaultSocketPath() }

    @ViewBuilder
    private var feedback: some View {
        if let problem = session.connectProblem {
            VStack(alignment: .leading, spacing: Space.sm) {
                ErrorMessage(error: problem)
                // S-068: a saved file that was moved or deleted.
                if session.form.transport == .sqlite, problem.code == SQLiteFile.missingCode {
                    HStack(spacing: Space.sm) {
                        Button("Locate…") { session.locateSQLiteFile(model: model) }
                            .help("Find the file and keep using this connection")
                        if let uid = session.selectedSaved {
                            Button("Remove Connection") {
                                model.delete(uid)
                                session.show(saved: nil)
                            }
                            .help("Delete this saved connection; the file isn't touched")
                        }
                    }
                }
            }
        } else if let result = session.testResult {
            switch result {
            case .success(let text):
                Label(text, systemImage: StatusStyle.successSymbol)
                    .foregroundStyle(StatusStyle.success)
                    .labelStyle(.titleAndIcon)
            case .failure(let error):
                ErrorMessage(error: error)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            Button(session.selectedSaved == nil ? "Save Connection" : "Save Changes") {
                session.selectedSaved = model.save(session.form, over: session.selectedSaved)
                if session.form.name.isEmpty { focus = .name }
            }
            .help("Save these details in the sidebar (⇧⌘A)")
            .disabled(session.phase == .connecting)

            Spacer()

            if session.isTesting {
                ProgressView().controlSize(.small)
            }
            Button("Test Connection") { Task { await session.testConnection() } }
                .help("Try these details without opening the connection")
                .disabled(session.phase == .connecting || session.isTesting)

            if session.phase == .connecting {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Connecting")
                Button("Cancel") { session.cancelConnect() }
                    .keyboardShortcut(.cancelAction)
                    .help("Stop connecting (Escape)")
            } else {
                Button("Connect") { session.connect(model: model) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .help("Connect to the server (Return)")
            }
        }
    }
}

/// The SQLite File fields (S-068): the file and Open Read Only.
private struct SQLiteFields: View {
    @Binding var form: ConnectionDetails
    var focus: FocusState<ConnectForm.Field?>.Binding

    var body: some View {
        LabeledContent("File") {
            HStack(spacing: Space.sm) {
                TextField("File", text: $form.file, prompt: Text("~/Documents/demo.sqlite"))
                    .labelsHidden()
                    .focused(focus, equals: .file)
                    .accessibilityLabel("File")
                Button("Choose…", action: choose)
                    .help("Choose a SQLite file")
            }
        }
        .help("The SQLite file to open. Quarry never makes a file here; use File > New SQLite File… (⌃⌘N).")
        Toggle("Open Read Only", isOn: $form.readOnly)
            .help("Open the file so nothing can write to it, not even Quarry")
    }

    private func choose() {
        guard let url = Session.chooseSQLiteFile(title: "Choose a SQLite File") else { return }
        form.file = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// The SSH section of the form (S-047): where to log in before reaching MySQL.
private struct SSHFields: View {
    @Binding var form: ConnectionDetails
    var focus: FocusState<ConnectForm.Field?>.Binding

    var body: some View {
        Section("SSH") {
            TextField("SSH Host", text: $form.sshHost)
                .focused(focus, equals: .sshHost)
                .help("The computer to log in to with SSH, which can reach the MySQL server")
            TextField("SSH User", text: $form.sshUser, prompt: Text(NSUserName()))
                .focused(focus, equals: .sshUser)
            SecureField("SSH Password", text: $form.sshPassword, prompt: Text("Optional"))
                .focused(focus, equals: .sshPassword)
                .help("The SSH password, or the SSH key's passphrase. Quarry asks when it is needed.")
            LabeledContent("SSH Key") {
                HStack(spacing: Space.sm) {
                    TextField("SSH Key", text: $form.sshKey, prompt: Text("Optional"))
                        .labelsHidden()
                        .focused(focus, equals: .sshKey)
                    Button("Choose…", action: chooseKey)
                        .help("Choose a private key file")
                }
            }
            .help("A private key file. Leave SSH Key and SSH Password empty to use your SSH agent and the keys in ~/.ssh.")
            TextField("SSH Port", text: $form.sshPort, prompt: Text(String(ConnectionDetails.defaultSSHPort)))
                .focused(focus, equals: .sshPort)
        }
    }

    /// An open panel in ~/.ssh, with hidden files shown.
    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "Choose an SSH Key"
        panel.prompt = "Choose"
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        form.sshKey = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// A server or network error next to the thing that caused it. The server's
/// words are selectable, so people can copy and search them.
struct ErrorMessage: View {
    let error: DatabaseError

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: StatusStyle.errorSymbol)
                .foregroundStyle(StatusStyle.error)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(error.message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let suggestion = error.suggestion {
                    Text(suggestion)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(error.message) \(error.suggestion ?? "")")
    }
}
