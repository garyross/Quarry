import Foundation
import QuarryKit

/// Self-test: connecting through an SSH host (S-047), against tools/testssh.sh.
extension SelfTest {
    static let testSSHFolder = NSHomeDirectory() + "/Library/Developer/Quarry/test-ssh"

    /// The test database through the test SSH host, with the locked key and no passphrase yet.
    static var sshDetails: ConnectionDetails {
        ConnectionDetails(name: "Through SSH", transport: .ssh, host: "127.0.0.1", port: "3399", user: "quarry",
                          password: "quarry", database: "quarry_demo", sshHost: "127.0.0.1", sshPort: "3398",
                          sshKey: testSSHFolder + "/client-locked")
    }

    /// Waits up to 10 s: each SSH login takes a moment.
    static func waitLong(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(25)) }
    }

    static func sshTunnel(model: AppModel, session: Session) async {
        guard FileManager.default.fileExists(atPath: testSSHFolder + "/sshd.pid") else {
            check("S-047 the test SSH host runs (tools/testssh.sh start)", false)
            return
        }
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent("quarry-selftest-known_hosts").path
        try? FileManager.default.removeItem(atPath: knownHosts)
        await TunnelPool.shared.configure(files: .init(knownHosts: knownHosts, config: "none"), idleGrace: .milliseconds(300))

        // connecting() leaves the window on Local for the browsing checks; come back to it at the end.
        let local = session.selectedSaved
        session.disconnect()
        let uid = model.save(sshDetails, over: nil)
        session.show(saved: model.savedConnection(uid))
        check("S-047 a saved SSH connection keeps its SSH fields", session.form == sshDetails)
        check("S-047 its sidebar row says where it goes", model.savedConnection(uid)?.summary == "quarry@127.0.0.1:3399 via 127.0.0.1")

        // An unknown host asks once.
        session.connect(model: model)
        await session.waitForConnect()
        var host: SSHTunnel.HostKey?
        if case .unknownHost(let key) = session.sshQuestion?.prompt { host = key }
        check("S-047 an unknown host key asks to trust it", host?.fingerprint.hasPrefix("SHA256:") == true && session.phase == .disconnected,
              session.connectProblem?.message ?? String(describing: session.sshQuestion))

        // Trust Host, then the locked key asks for its passphrase.
        session.trustSSHHost(model: model)
        await waitLong { session.sshQuestion != nil || session.connectProblem != nil }
        check("S-047 a locked key asks for its passphrase", session.sshQuestion?.prompt == .passphrase(sshDetails.sshKey),
              session.connectProblem?.message ?? String(describing: session.sshQuestion))
        check("S-047 trusting wrote the key to known_hosts",
              (try? String(contentsOfFile: knownHosts, encoding: .utf8))?.contains("ssh-ed25519") == true)

        session.answerSSH(secret: "quarry", remember: true, model: model)
        await waitLong { session.phase == .connected || session.connectProblem != nil }
        await session.waitForConnect()
        check("S-047 connects through the SSH host", session.phase == .connected && session.database == "quarry_demo",
              session.connectProblem?.message ?? "")
        check("S-047 the passphrase can be saved in the Keychain", PasswordStore.password(for: uid, ssh: true) == "quarry")

        // Cancel and an export reuse the one ssh.
        if let client = session.client {
            try? await client.cancelRunningQuery()
            let second = try? await client.secondConnection()
            check("S-047 Cancel and a second connection share one ssh", await TunnelPool.shared.tunnelCount == 1)
            await second?.close()
        }
        session.disconnect()
        try? await Task.sleep(for: .seconds(1))
        check("S-047 ssh stops after the last connection closes", await TunnelPool.shared.tunnelCount == 0)

        // Saved and trusted: no questions the second time.
        session.show(saved: model.savedConnection(uid))
        session.connect(model: model)
        await session.waitForConnect()
        check("S-047 a saved, trusted connection connects without asking",
              session.phase == .connected && session.sshQuestion == nil, session.connectProblem?.message ?? "")
        session.disconnect()

        // The SSH host cannot reach MySQL there.
        var unreachable = sshDetails
        unreachable.sshPassword = "quarry"
        unreachable.port = "3397"
        session.form = unreachable
        session.connect(model: model)
        await session.waitForConnect()
        check("S-047 says when the SSH host cannot reach MySQL",
              session.connectProblem?.message == "The SSH host could not reach the MySQL server at 127.0.0.1:3397.",
              session.connectProblem?.message ?? "no error")

        // A wrong SSH port.
        var closed = sshDetails
        closed.sshPort = "3396"
        session.form = closed
        session.connect(model: model)
        await session.waitForConnect()
        check("S-047 says when the SSH host cannot be reached",
              session.connectProblem?.message == "Could not reach the SSH host 127.0.0.1:3396.", session.connectProblem?.message ?? "no error")
        model.delete(uid)
        session.show(saved: model.savedConnection(local))
        session.connect(model: model)
        await session.waitForConnect()
    }
}
