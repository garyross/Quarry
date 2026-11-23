import Foundation
import Testing
@testable import QuarryKit
import QuarryTestSupport

/// S-047: the ssh command, what its questions and errors mean, and the SSH fields.
struct SSHTunnelTests {
    let socket = "/tmp/q/mysql.sock"

    @Test func keyModeUsesOnlyThatKey() {
        let login = SSHTunnel.Login(host: "staging", port: 2222, user: "deploy", keyFile: "/k/id", secret: "pass")
        #expect(login.mode == .key)
        let args = SSHTunnel.arguments(login, targetHost: "127.0.0.1", targetPort: 3306, socketPath: socket)
        #expect(args.contains("-N"))
        #expect(args.containsPair("-i", "/k/id"))
        #expect(args.containsPair("-o", "IdentitiesOnly=yes"))
        #expect(args.containsPair("-o", "StrictHostKeyChecking=ask"))
        #expect(args.containsPair("-o", "ExitOnForwardFailure=yes"))
        #expect(args.containsPair("-p", "2222"))
        #expect(args.containsPair("-l", "deploy"))
        #expect(args.containsPair("-L", "/tmp/q/mysql.sock:127.0.0.1:3306"))
        #expect(Array(args.suffix(2)) == ["--", "staging"])
        #expect(!args.contains("PubkeyAuthentication=no"))
    }

    @Test func passwordModeSkipsKeys() {
        let login = SSHTunnel.Login(host: "staging", user: "deploy", secret: "pass")
        #expect(login.mode == .password)
        let args = SSHTunnel.arguments(login, targetHost: "db", targetPort: 3306, socketPath: socket)
        #expect(args.containsPair("-o", "PubkeyAuthentication=no"))
        #expect(args.containsPair("-o", "NumberOfPasswordPrompts=1"))
        #expect(!args.contains("-i"))
        #expect(args.containsPair("-p", "22"))
        // The password is never an argument.
        #expect(!args.contains("pass"))
    }

    @Test func agentModeAddsNoAuthOptions() {
        let login = SSHTunnel.Login(host: "staging", user: "deploy")
        #expect(login.mode == .agent)
        let args = SSHTunnel.arguments(login, targetHost: "::1", targetPort: 3306, socketPath: socket)
        #expect(!args.contains("-i"))
        #expect(!args.contains("PubkeyAuthentication=no"))
        #expect(args.containsPair("-L", "/tmp/q/mysql.sock:[::1]:3306"))
    }

    @Test func aHostThatLooksLikeAnOptionStaysAHost() {
        let login = SSHTunnel.Login(host: "-oProxyCommand=evil", user: "u")
        let args = SSHTunnel.arguments(login, targetHost: "db", targetPort: 3306, socketPath: socket)
        #expect(Array(args.suffix(2)) == ["--", "-oProxyCommand=evil"])
    }

    @Test func testFilesAreUsed() {
        let login = SSHTunnel.Login(host: "h", user: "u")
        let args = SSHTunnel.arguments(login, targetHost: "db", targetPort: 1, socketPath: socket,
                                       files: .init(knownHosts: "/t/kh", config: "none"))
        #expect(args.containsPair("-F", "none"))
        #expect(args.containsPair("-o", "UserKnownHostsFile=/t/kh"))
    }

    @Test func readsAskpassQuestions() {
        let host = """
            The authenticity of host '[127.0.0.1]:3398 ([127.0.0.1]:3398)' can't be established.
            ED25519 key fingerprint is SHA256:AbC+/12=.
            This key is not known by any other names.
            Are you sure you want to continue connecting (yes/no/[fingerprint])?
            """
        #expect(SSHTunnel.prompt(host) == .unknownHost(.init(host: "[127.0.0.1]:3398", type: "ED25519", fingerprint: "SHA256:AbC+/12=")))
        #expect(SSHTunnel.prompt("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ") == .passphrase("/Users/me/.ssh/id_ed25519"))
        #expect(SSHTunnel.prompt("deploy@staging's password: ") == .password)
        #expect(SSHTunnel.prompt("(deploy@staging) Password: ") == .password)
        #expect(SSHTunnel.prompt("Something else") == nil)
    }

    @Test func anUnknownHostIsAQuestion() {
        let login = SSHTunnel.Login(host: "h", user: "u")
        let prompt = "The authenticity of host 'h (1.2.3.4)' can't be established.\nED25519 key fingerprint is SHA256:xyz.\nAre you sure you want to continue connecting (yes/no/[fingerprint])?"
        let error = SSHTunnel.failure(stderr: "Host key verification failed.", prompts: [prompt], login: login, trusted: nil)
        #expect((error as? SSHQuestion)?.prompt == .unknownHost(.init(host: "h", type: "ED25519", fingerprint: "SHA256:xyz")))
        // Trusted, but ssh still failed: an error, not the same question again.
        let after = SSHTunnel.failure(stderr: "Host key verification failed.", prompts: [prompt], login: login, trusted: "SHA256:xyz")
        #expect(after is DatabaseError)
    }

    @Test func aMissingSecretIsAQuestionAndAWrongOneAnError() {
        let key = SSHTunnel.Login(host: "h", user: "u", keyFile: "/k")
        let asked = SSHTunnel.failure(stderr: "Permission denied (publickey).", prompts: ["Enter passphrase for key '/k': "],
                                      login: key, trusted: nil)
        #expect((asked as? SSHQuestion)?.prompt == .passphrase("/k"))
        var withSecret = key
        withSecret.secret = "wrong"
        let wrong = SSHTunnel.failure(stderr: "Permission denied (publickey).", prompts: ["Enter passphrase for key '/k': "],
                                      login: withSecret, trusted: nil)
        #expect((wrong as? DatabaseError)?.message == "The SSH host did not accept the login for u.")
        #expect((wrong as? DatabaseError)?.suggestion == "Check the SSH user and the key's passphrase.")
    }

    @Test func mapsSSHErrorsToWords() {
        let login = SSHTunnel.Login(host: "staging", port: 2222, user: "deploy", keyFile: "/k")
        func message(_ stderr: String) -> String? {
            (SSHTunnel.failure(stderr: stderr, prompts: [], login: login, trusted: nil) as? DatabaseError)?.message
        }
        #expect(message("ssh: Could not resolve hostname staging: nodename nor servname provided") == "Could not find the SSH host \"staging\".")
        #expect(message("ssh: connect to host staging port 2222: Connection refused") == "Could not reach the SSH host staging:2222.")
        #expect(message("ssh: connect to host staging port 2222: Operation timed out") == "Could not reach the SSH host staging:2222.")
        #expect(message("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@") == "The key for staging has changed since you trusted it.")
        #expect(message("Warning: Identity file /k not accessible: No such file or directory.\nPermission denied (publickey).") == "There is no SSH key at /k.")
        #expect(message("WARNING: UNPROTECTED PRIVATE KEY FILE!\nbad permissions") == "Other users can read the SSH key at /k, so ssh will not use it.")
        #expect(message("Permission denied (publickey).") == "The SSH host did not accept the login for deploy.")
        #expect(message("setsockopt TCP_NODELAY: Operation not supported\nkex_exchange_identification: read: Connection reset by peer")
                == "The SSH connection to staging:2222 failed: kex_exchange_identification: read: Connection reset by peer")
    }

    @Test func detailsFillSSHBlanks() throws {
        let details = ConnectionDetails(transport: .ssh, host: "", port: "", user: "quarry",
                                        sshHost: " staging ", sshKey: "~/.ssh/id")
        let login = try #require(details.ssh)
        #expect(login.host == "staging")
        #expect(login.port == 22)
        #expect(login.user == NSUserName())
        #expect(login.keyFile == NSHomeDirectory() + "/.ssh/id")
        #expect(login.secret == nil)
        #expect(details.driverConfiguration.socketPath == nil)
        #expect(details.driverConfiguration.host == "127.0.0.1")
        #expect(details.displayName == "staging")
        #expect(ConnectionDetails(transport: .tcp, sshHost: "x").ssh == nil)
    }

    @Test func sshProblems() {
        #expect(ConnectionDetails(transport: .ssh, user: "u").problem == "Enter an SSH host.")
        #expect(ConnectionDetails(transport: .ssh, user: "u", sshHost: "h", sshPort: "99999").problem == "The SSH port must be a number from 1 to 65535.")
        #expect(ConnectionDetails(transport: .ssh, user: "u", sshHost: "h").problem == nil)
    }
}

/// S-047 against tools/testssh.sh and tools/testdb.sh. Skipped when either is off.
@Suite("SSH tunnel", .serialized, .enabled(if: TestServer.isRunning && TestSSH.isRunning))
struct SSHTunnelServerTests {
    @Test func trustsOnceThenSharesOneTunnel() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quarry-ssh-test-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let knownHosts = folder.appendingPathComponent("known_hosts").path
        let pool = TunnelPool()
        await pool.configure(files: .init(knownHosts: knownHosts, config: "none"), idleGrace: .milliseconds(200))
        let login = TestSSH.login(key: "client")

        // First login: an unknown host key is a question, and nothing was written.
        let question = await #expect(throws: SSHQuestion.self) { try await pool.open(login, to: "127.0.0.1", port: 3399) }
        guard case .unknownHost(let key) = question?.prompt else { Issue.record("no host question"); return }
        #expect(key.fingerprint.hasPrefix("SHA256:"))
        #expect(!FileManager.default.fileExists(atPath: knownHosts))

        // Trust Host: ssh writes the key, and two connections share one ssh.
        await pool.trust(key, for: login)
        let first = try await pool.open(login, to: "127.0.0.1", port: 3399)
        let second = try await pool.open(login, to: "127.0.0.1", port: 3399)
        #expect(first.socketPath == second.socketPath)
        #expect(await pool.tunnelCount == 1)
        #expect(try String(contentsOfFile: knownHosts, encoding: .utf8).contains("ssh-ed25519"))

        // The last release stops it after the grace.
        await pool.release(first)
        await pool.release(second)
        #expect(await pool.tunnelCount == 1)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await pool.tunnelCount == 0)
        #expect(!FileManager.default.fileExists(atPath: first.socketPath))
    }

    @Test func connectsThroughTheTunnel() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quarry-ssh-test-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        await TunnelPool.shared.configure(files: .init(knownHosts: folder.appendingPathComponent("kh").path, config: "none"))
        var details = TestSSH.details(key: "client-locked")

        // A locked key without its passphrase asks for it.
        let question = await #expect(throws: SSHQuestion.self) {
            do { _ = try await DatabaseClient.connect(details) } catch let asked as SSHQuestion {
                guard case .unknownHost(let key) = asked.prompt else { throw asked }
                await TunnelPool.shared.trust(key, for: asked.login)
                _ = try await DatabaseClient.connect(details)
            }
        }
        #expect(question?.prompt == .passphrase(details.sshKey))

        details.sshPassword = "quarry"
        let client = try await DatabaseClient.connect(details)
        let rows = try await client.run("SELECT 1 AS one")
        #expect(rows.string(0, "one") == "1")
        // Cancel's second connection reuses the tunnel.
        try await client.cancelRunningQuery()
        #expect(await TunnelPool.shared.tunnelCount == 1)
        await client.close()

        // The SSH host cannot reach MySQL there.
        var unreachable = details
        unreachable.port = "3397"
        let error = await #expect(throws: DatabaseError.self) { try await DatabaseClient.connect(unreachable) }
        #expect(error?.message == "The SSH host could not reach the MySQL server at 127.0.0.1:3397.")
    }
}

enum TestSSH {
    static let folder = NSHomeDirectory() + "/Library/Developer/Quarry/test-ssh"

    static func login(key: String) -> SSHTunnel.Login {
        SSHTunnel.Login(host: "127.0.0.1", port: 3398, user: NSUserName(), keyFile: folder + "/" + key)
    }

    static func details(key: String) -> ConnectionDetails {
        ConnectionDetails(name: "SSH", transport: .ssh, host: "127.0.0.1", port: "3399", user: "quarry",
                          password: "quarry", database: "quarry_demo", sshHost: "127.0.0.1", sshPort: "3398",
                          sshKey: folder + "/" + key)
    }

    static var isRunning: Bool {
        guard let pid = try? String(contentsOfFile: folder + "/sshd.pid", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), let number = Int32(pid) else { return false }
        return kill(number, 0) == 0
    }
}

extension Array where Element == String {
    func containsPair(_ flag: String, _ value: String) -> Bool {
        zip(self, dropFirst()).contains { $0 == flag && $1 == value }
    }
}
