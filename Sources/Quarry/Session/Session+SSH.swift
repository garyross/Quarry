import Foundation
import QuarryKit

/// What answering an SSH question tries again.
enum SSHRetry { case connect, test }

/// SSH's questions while connecting (S-047), Sequel Pro's SSHQuestionDialog:
/// Trust Host for a key not seen before, and a password or passphrase that
/// was not saved. Each answer tries Connect (or Test Connection) again.
extension Session {
    func ask(_ question: SSHQuestion, retry: SSHRetry) {
        sshRetry = retry
        sshQuestion = question
    }

    /// Trust Host (Return): `ssh` accepts this key once and writes it to known_hosts.
    func trustSSHHost(model: AppModel?) {
        guard let question = sshQuestion, case .unknownHost(let key) = question.prompt else { return }
        sshQuestion = nil
        Task {
            await TunnelPool.shared.trust(key, for: question.login)
            retryAfterSSH(model: model)
        }
    }

    /// Connect (Return) in the password sheet. A passphrase for one of the keys
    /// in ~/.ssh fills SSH Key, so the next login uses that key. Remember in
    /// Keychain stores it with the saved connection or favorite.
    func answerSSH(secret: String, remember: Bool, model: AppModel?) {
        guard let question = sshQuestion else { return }
        sshQuestion = nil
        form.sshPassword = secret
        if case .passphrase(let key) = question.prompt, form.sshKey.trimmingCharacters(in: .whitespaces).isEmpty {
            form.sshKey = (key as NSString).abbreviatingWithTildeInPath
        }
        if remember, let uid = selectedSaved ?? selectedFavorite {
            PasswordStore.setPassword(secret, for: uid, ssh: true)
            model?.rememberSSHKey(form.sshKey, for: uid)
        }
        retryAfterSSH(model: model)
    }

    /// Whether the password sheet can remember its answer: only for a saved connection or favorite.
    var canRememberSSHSecret: Bool { selectedSaved != nil || selectedFavorite != nil }

    /// Cancel (Escape): back to the form, nothing tried.
    func cancelSSHQuestion() {
        sshQuestion = nil
    }

    private func retryAfterSSH(model: AppModel?) {
        switch sshRetry {
        case .connect: connect(model: model ?? self.model)
        case .test: Task { await testConnection() }
        }
    }
}
