import QuarryKit
import SwiftUI

/// SSH's questions while connecting (S-047), Sequel Pro's SSHQuestionDialog:
/// Trust Host for a key Quarry has not seen, or a password or passphrase.
struct SSHQuestionSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: Session
    let question: SSHQuestion
    @State private var secret = ""
    @State private var remember = true
    @FocusState private var secretFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    message
                }
            }
            .gridProbe("message", area: "ssh-question")
            HStack(spacing: Space.sm) {
                Spacer()
                Button("Cancel") { session.cancelSSHQuestion() }
                    .keyboardShortcut(.cancelAction)
                    .help("Go back to the form without connecting (Escape)")
                confirm
            }
            .gridProbe("buttons", area: "ssh-question")
        }
        .padding(Space.margin)
        .frame(width: Layout.sshQuestionWidth)
        .gridArea("ssh-question")
        // The password sheet's only job is typing, so its field has focus; Trust Host opens calm.
        .background { if isTrust { Color.clear.noInitialFocus() } }
        .onAppear { if !isTrust { secretFocused = true } }
    }

    private var isTrust: Bool {
        if case .unknownHost = question.prompt { true } else { false }
    }

    private var symbol: String { isTrust ? "checkmark.shield" : "key" }

    private var title: String {
        switch question.prompt {
        case .unknownHost(let key): "Trust \(key.host)?"
        case .password: "SSH Password Required"
        case .passphrase: "SSH Key Passphrase Required"
        }
    }

    @ViewBuilder
    private var message: some View {
        switch question.prompt {
        case .unknownHost(let key):
            Text("Quarry has not connected to this SSH host before. Check that its key fingerprint matches the one its administrator gave you.")
                .fixedSize(horizontal: false, vertical: true)
            Text("\(key.type) \(key.fingerprint)")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Fingerprint: \(key.type) \(key.fingerprint)")
            Text("Trust Host remembers it in ~/.ssh/known_hosts.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .password, .passphrase:
            Text(question.localizedDescription)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(isPassphrase ? "Passphrase" : "SSH Password", text: $secret)
                .focused($secretFocused)
                .onSubmit(answer)
            if session.canRememberSSHSecret {
                Toggle("Remember in Keychain", isOn: $remember)
                    .help("Save it with this connection, so Quarry does not ask again")
            }
        }
    }

    private var isPassphrase: Bool {
        if case .passphrase = question.prompt { true } else { false }
    }

    @ViewBuilder
    private var confirm: some View {
        if isTrust {
            Button("Trust Host") { session.trustSSHHost(model: model) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .help("Remember this host's key and connect (Return)")
        } else {
            Button(session.sshRetry == .test ? "Test Connection" : "Connect", action: answer)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(secret.isEmpty)
                .help("Log in to the SSH host with it (Return)")
        }
    }

    private func answer() {
        guard !secret.isEmpty else { return }
        session.answerSSH(secret: secret, remember: remember && session.canRememberSSHSecret, model: model)
    }
}
