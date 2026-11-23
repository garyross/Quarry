import AppKit
import Foundation

/// `Quarry mcp` (S-063): what an agent's stdio MCP client runs. Passes each
/// line from stdin to the running app's MCP socket and each answer back to
/// stdout. Opens Quarry in the background when it isn't running. When the
/// server is off, it answers every request with how to turn it on.
nonisolated enum MCPBridge {
    static func run(socketPath: String) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        var socket = connect(socketPath)
        if socket < 0, !appIsRunning() {
            launchApp()
            for _ in 0..<75 where socket < 0 {
                Thread.sleep(forTimeInterval: 0.2)
                socket = connect(socketPath)
            }
        }
        guard socket >= 0 else { return answerOffline() }
        let connected = socket

        // Answers from the app to stdout, until the app closes the socket.
        let reader = Thread {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(connected, &buffer, buffer.count)
                if count <= 0 { break }
                buffer.withUnsafeBytes { raw in _ = fwrite(raw.baseAddress, 1, count, stdout) }
                fflush(stdout)
            }
            // Quarry quit: the agent's client starts the bridge again when it needs it.
            exit(0)
        }
        reader.start()
        // Requests from stdin to the app.
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            if !send(Data((line + "\n").utf8), to: connected) { break }
        }
        shutdown(connected, SHUT_WR)
        // Let the last answers through before leaving.
        Thread.sleep(forTimeInterval: 0.5)
        return 0
    }

    static let offlineMessage = "Quarry's MCP server is off. Turn on Enable MCP Server in Quarry > Settings > MCP, then reconnect."

    /// With no server, every request gets an error that says how to turn it on.
    private static func answerOffline() -> Int32 {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = message["id"], message["method"] != nil else { continue }
            let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": offlineMessage]]
            if let out = try? JSONSerialization.data(withJSONObject: reply) {
                FileHandle.standardOutput.write(out + Data("\n".utf8))
            }
        }
        return 0
    }

    // MARK: The app

    /// The app bundle this binary belongs to, with any symlink followed.
    private static var bundleURL: URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        let bundle = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return bundle.pathExtension == "app" ? bundle : nil
    }

    private static func appIsRunning() -> Bool {
        // A test run (APP_STORE) always has its own copy.
        guard ProcessInfo.processInfo.environment["APP_STORE"] == nil else { return true }
        let id = bundleURL.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "app.quarry.mac"
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    /// Opens Quarry in the background, as if from the Dock.
    private static func launchApp() {
        guard let bundle = bundleURL else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: Socket

    private static func connect(_ path: String) -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(fd); return -1 }
        return fd
    }

    private static func send(_ data: Data, to socket: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = write(socket, raw.baseAddress! + offset, raw.count - offset)
                if sent <= 0 { return false }
                offset += sent
            }
            return true
        }
    }
}
