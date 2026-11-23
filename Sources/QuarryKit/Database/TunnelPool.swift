import Foundation

/// One `ssh` process per SSH login and MySQL server, shared by every
/// connection that goes through it (S-047): a window, its tabs, Cancel's
/// KILL QUERY, exports and imports. It stops a short while after the last
/// connection closes, so Cancel and Reconnect do not wait for a new login.
///
/// The tunnel ends in a Unix socket inside a folder only this user can open,
/// so no one else on the Mac can use it.
public actor TunnelPool {
    public static let shared = TunnelPool()

    /// A connection's use of a tunnel; give it back with `release`.
    public struct Lease: Sendable, Hashable {
        let key: Key
        let id: UUID
        public let socketPath: String
    }

    struct Key: Sendable, Hashable {
        var host: String
        var port: Int
        var user: String
        var keyFile: String?
        var targetHost: String
        var targetPort: Int
    }

    /// Changed only on the pool actor; Sendable so a starting task can hand it back.
    private final class Tunnel: @unchecked Sendable {
        let process: Process
        let folder: URL
        let socketPath: String
        /// `ssh`'s error output, still read while the tunnel is up.
        let stderr: OutputBuffer
        var users = 0
        var idle: Task<Void, Never>?

        init(process: Process, folder: URL, socketPath: String, stderr: OutputBuffer) {
            self.process = process
            self.folder = folder
            self.socketPath = socketPath
            self.stderr = stderr
        }
    }

    private var tunnels: [Key: Tunnel] = [:]
    private var starting: [Key: Task<Tunnel, any Error>] = [:]
    /// Fingerprints people trusted in this run, per SSH host and port.
    private var trusted: [String: String] = [:]
    private var files = SSHTunnel.Files()
    private var idleGrace: Duration = .seconds(10)
    /// Every running `ssh`, so the app can stop them as it quits.
    private nonisolated let running = Running()

    public init() {}

    /// Test seams: a separate known_hosts and ssh config, and a shorter wait before stopping.
    public func configure(files: SSHTunnel.Files, idleGrace: Duration? = nil) {
        self.files = files
        if let idleGrace { self.idleGrace = idleGrace }
    }

    /// Trust Host: the next login to this SSH host accepts the key with this fingerprint,
    /// and `ssh` writes it to known_hosts.
    public func trust(_ key: SSHTunnel.HostKey, for login: SSHTunnel.Login) {
        trusted["\(login.host):\(login.port)"] = key.fingerprint
    }

    /// A socket that reaches `targetHost:targetPort` through `login`, starting
    /// `ssh` if no tunnel is up. Throws `SSHQuestion` or `DatabaseError`.
    public func open(_ login: SSHTunnel.Login, to targetHost: String, port targetPort: Int) async throws -> Lease {
        let key = Key(host: login.host, port: login.port, user: login.user, keyFile: login.keyFile,
                      targetHost: targetHost, targetPort: targetPort)
        let tunnel: Tunnel
        if let up = tunnels[key], up.process.isRunning {
            tunnel = up
        } else if let pending = starting[key] {
            tunnel = try await Self.wait(for: pending)
        } else {
            let task = Task { try await start(login, key: key) }
            starting[key] = task
            defer { starting[key] = nil }
            tunnel = try await Self.wait(for: task)
            tunnels[key] = tunnel
        }
        tunnel.users += 1
        tunnel.idle?.cancel()
        tunnel.idle = nil
        return Lease(key: key, id: UUID(), socketPath: tunnel.socketPath)
    }

    /// Cancelling the caller (Cancel on the Connect page) stops `ssh` too.
    private static func wait(for task: Task<Tunnel, any Error>) async throws -> Tunnel {
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// One connection stopped using its tunnel. The last one stops it after `idleGrace`.
    public func release(_ lease: Lease) {
        guard let tunnel = tunnels[lease.key], tunnel.socketPath == lease.socketPath else { return }
        tunnel.users = max(0, tunnel.users - 1)
        guard tunnel.users == 0 else { return }
        let grace = idleGrace
        tunnel.idle = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle(lease.key, socketPath: lease.socketPath)
        }
    }

    /// How many forwarded connections the SSH host could not open to MySQL
    /// ("channel 2: open failed: connect failed"). MySQL's handshake waits
    /// forever on such a connection, so `DatabaseClient.connect` watches this.
    public func openFailures(_ lease: Lease) -> Int {
        guard let tunnel = tunnels[lease.key], tunnel.socketPath == lease.socketPath else { return 0 }
        return tunnel.stderr.text.components(separatedBy: "open failed").count - 1
    }

    /// How many `ssh` processes run (self-test).
    public var tunnelCount: Int { tunnels.values.filter(\.process.isRunning).count }

    /// Stops every `ssh` at once, as the app quits.
    public nonisolated func stopAll() {
        running.terminateAll()
    }

    private func stopIfIdle(_ key: Key, socketPath: String) {
        guard let tunnel = tunnels[key], tunnel.socketPath == socketPath, tunnel.users == 0 else { return }
        tunnels[key] = nil
        stop(tunnel)
    }

    private func stop(_ tunnel: Tunnel) {
        if tunnel.process.isRunning { tunnel.process.terminate() }
        running.remove(tunnel.process)
        try? FileManager.default.removeItem(at: tunnel.folder)
    }

    /// `ssh` ended by itself (the network dropped, the SSH host restarted):
    /// forget it, so the next connection starts a new one.
    private func ended(_ process: Process) {
        running.remove(process)
        for (key, tunnel) in tunnels where tunnel.process === process {
            tunnels[key] = nil
            try? FileManager.default.removeItem(at: tunnel.folder)
        }
    }

    // MARK: Starting ssh

    private func start(_ login: SSHTunnel.Login, key: Key) async throws -> Tunnel {
        let folder = try Self.makeFolder()
        let socketPath = folder.appendingPathComponent("mysql.sock").path
        let askpass = folder.appendingPathComponent("askpass")
        let fileManager = FileManager.default
        do {
            try Data(SSHTunnel.askpassScript.utf8).write(to: askpass)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
            let trustedPrint = trusted["\(login.host):\(login.port)"]
            if let trustedPrint {
                try Self.writePrivate(trustedPrint + "\n", to: folder.appendingPathComponent("trusted"))
            }
            if let secret = login.secret {
                try Self.writePrivate(secret, to: folder.appendingPathComponent("secret"))
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = SSHTunnel.arguments(login, targetHost: key.targetHost, targetPort: key.targetPort,
                                                    socketPath: socketPath, files: files)
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS"] = askpass.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["QUARRY_SSH_FOLDER"] = folder.path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            let stderr = OutputBuffer()
            errors.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { stderr.append(data) }
            }
            process.terminationHandler = { [weak self] ended in
                Task { await self?.ended(ended) }
            }
            try process.run()
            running.add(process)

            // Wait for the socket (the login is done and the forward listens), for ssh to stop, or for Cancel.
            let deadline = ContinuousClock.now + .seconds(30)
            var up = false
            var timedOut = true
            while ContinuousClock.now < deadline {
                if fileManager.fileExists(atPath: socketPath) { up = true }
                if up || !process.isRunning || Task.isCancelled { timedOut = false; break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            try? fileManager.removeItem(at: folder.appendingPathComponent("secret"))
            if up, process.isRunning {
                return Tunnel(process: process, folder: folder, socketPath: socketPath, stderr: stderr)
            }
            let cancelled = Task.isCancelled
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            running.remove(process)
            try? await Task.sleep(for: .milliseconds(50))  // the last of stderr
            let prompts = ((try? String(contentsOf: folder.appendingPathComponent("prompts"), encoding: .utf8)) ?? "")
                .split(separator: "\0").map(String.init)
            try? fileManager.removeItem(at: folder)
            if cancelled { throw CancellationError() }
            if timedOut {
                throw DatabaseError(message: "The SSH host \(login.host) did not answer in time.",
                                    suggestion: "Check that the SSH host is on and the SSH port is right.")
            }
            throw SSHTunnel.failure(stderr: stderr.text, prompts: prompts, login: login, trusted: trustedPrint)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    /// A new folder only this user can open, with a path short enough for a socket.
    private static func makeFolder() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("quarry-ssh-" + UUID().uuidString.prefix(8).lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    private static func writePrivate(_ text: String, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try Data(text.utf8).write(to: url)
    }
}

/// `ssh`'s error output, collected from a background handler.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    /// Keeps the last 64 KB.
    func append(_ more: Data) {
        lock.withLock {
            data.append(more)
            if data.count > 64 * 1024 { data.removeFirst(data.count - 64 * 1024) }
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// The running `ssh` processes, for `stopAll` while the app quits.
private final class Running: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func add(_ process: Process) { lock.withLock { processes[ObjectIdentifier(process)] = process } }
    func remove(_ process: Process) { lock.withLock { processes[ObjectIdentifier(process)] = nil } }

    func terminateAll() {
        let all = lock.withLock { Array(processes.values) }
        for process in all where process.isRunning { process.terminate() }
    }
}
