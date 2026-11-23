import AppKit
import QuarryKit
import SwiftUI

/// The SSL section of the Connect form (S-058), for every connection type:
/// Use SSL, then the key, certificate and CA files once it is on.
struct SSLFields: View {
    @Binding var form: ConnectionDetails
    var focus: FocusState<ConnectForm.Field?>.Binding

    var body: some View {
        Section("SSL") {
            Toggle("Use SSL", isOn: $form.useSSL)
                .help("Encrypt the connection. Quarry won't connect if the server doesn't offer SSL.")
            if form.useSSL {
                FileField(title: "Key File", path: $form.sslKey, field: .sslKey, focus: focus,
                          help: "Your private key (PEM), with Certificate, for accounts that require one",
                          panelTitle: "Choose a Key File")
                FileField(title: "Certificate", path: $form.sslCertificate, field: .sslCertificate, focus: focus,
                          help: "Your certificate (PEM), with Key File, for accounts that require one",
                          panelTitle: "Choose a Certificate")
                FileField(title: "CA Certificate", path: $form.sslCA, field: .sslCA, focus: focus,
                          help: "The authority that signed the server's certificate (PEM). Leave empty to encrypt without checking the server.",
                          panelTitle: "Choose a CA Certificate")
            }
        }
    }
}

/// A path field with Choose…, which opens a panel and fills in the path with `~`.
private struct FileField: View {
    let title: String
    @Binding var path: String
    let field: ConnectForm.Field
    var focus: FocusState<ConnectForm.Field?>.Binding
    let help: String
    let panelTitle: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: Space.sm) {
                TextField(title, text: $path, prompt: Text("Optional"))
                    .labelsHidden()
                    .focused(focus, equals: field)
                Button("Choose…", action: choose)
                    .help(panelTitle)
                    .accessibilityLabel("Choose \(title)")
            }
        }
        .help(help)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = panelTitle
        panel.prompt = "Choose"
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let current = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = (url.path as NSString).abbreviatingWithTildeInPath
    }
}
