import Foundation

/// What the Connect form collects. Fields are kept as typed; `driverConfiguration`
/// turns them into what the driver needs.
public struct ConnectionDetails: Sendable, Equatable, Codable {
    public static let defaultPort = 3306
    public static let defaultHost = "127.0.0.1"

    /// How Quarry reaches the server.
    public enum Transport: String, Sendable, Codable, CaseIterable, Identifiable {
        /// Host and port.
        case tcp
        /// A Unix socket file on this Mac.
        case socket
        /// Host and port as an SSH host sees them, through an SSH tunnel (S-047).
        case ssh
        /// A SQLite file on this Mac (S-068): no server, user or password.
        case sqlite

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .tcp: "TCP/IP"
            case .socket: "Socket"
            case .ssh: "SSH"
            case .sqlite: "SQLite File"
            }
        }
    }

    /// Where local servers usually put their socket, most common first:
    /// MySQL's default, Homebrew (Apple silicon, Intel), MAMP, macOS packages.
    public static let commonSocketPaths = [
        "/tmp/mysql.sock",
        "/opt/homebrew/var/mysql/mysql.sock",
        "/usr/local/var/mysql/mysql.sock",
        "/Applications/MAMP/tmp/mysql/mysql.sock",
        "/var/mysql/mysql.sock",
    ]

    /// The first common socket path that exists, or MySQL's default.
    public static func defaultSocketPath(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        commonSocketPaths.first(where: exists) ?? commonSocketPaths[0]
    }

    public var name: String
    public var transport: Transport
    public var host: String
    public var port: String
    /// The socket file's path; empty means the first of `commonSocketPaths` that exists.
    public var socket: String
    public var user: String
    public var password: String
    public var database: String
    /// The SSH host, for `.ssh` (S-047).
    public var sshHost: String
    /// Empty means 22.
    public var sshPort: String
    /// Empty means the Mac's user name, as `ssh` does.
    public var sshUser: String
    /// The SSH password, or the SSH key's passphrase when `sshKey` is set.
    public var sshPassword: String
    /// A private key file; empty with no SSH password uses the agent and ~/.ssh.
    public var sshKey: String
    /// Encrypt the connection with SSL (S-058), for any transport.
    public var useSSL: Bool
    /// The client's key and certificate files, for `REQUIRE X509` accounts; both or neither.
    public var sslKey: String
    public var sslCertificate: String
    /// The CA certificate the server's certificate must be signed by; empty checks nothing.
    public var sslCA: String
    /// The SQLite file's path, for `.sqlite` (S-068); `~` is expanded.
    public var file: String
    /// Open the SQLite file with SQLITE_OPEN_READONLY, so nothing can write (S-068).
    public var readOnly: Bool

    public init(name: String = "", transport: Transport = .tcp, host: String = "", port: String = "",
                socket: String = "", user: String = "", password: String = "", database: String = "",
                sshHost: String = "", sshPort: String = "", sshUser: String = "", sshPassword: String = "",
                sshKey: String = "", useSSL: Bool = false, sslKey: String = "", sslCertificate: String = "",
                sslCA: String = "", file: String = "", readOnly: Bool = false) {
        self.name = name
        self.transport = transport
        self.host = host
        self.port = port
        self.socket = socket
        self.user = user
        self.password = password
        self.database = database
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.sshUser = sshUser
        self.sshPassword = sshPassword
        self.sshKey = sshKey
        self.useSSL = useSSL
        self.sslKey = sslKey
        self.sslCertificate = sslCertificate
        self.sslCA = sslCA
        self.file = file
        self.readOnly = readOnly
    }

    /// A saved form from before S-068 has no file fields.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: key) ?? "" }
        self.init(name: try text(.name), transport: try c.decodeIfPresent(Transport.self, forKey: .transport) ?? .tcp,
                  host: try text(.host), port: try text(.port), socket: try text(.socket), user: try text(.user),
                  password: try text(.password), database: try text(.database), sshHost: try text(.sshHost),
                  sshPort: try text(.sshPort), sshUser: try text(.sshUser), sshPassword: try text(.sshPassword),
                  sshKey: try text(.sshKey), useSSL: try c.decodeIfPresent(Bool.self, forKey: .useSSL) ?? false,
                  sslKey: try text(.sslKey), sslCertificate: try text(.sslCertificate), sslCA: try text(.sslCA),
                  file: try text(.file), readOnly: try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false)
    }

    /// The SQLite file, with `~` expanded; nil for a server connection or an empty field.
    public var fileURL: URL? {
        guard transport == .sqlite else { return nil }
        let trimmed = file.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }

    public static let defaultSSHPort = 22

    /// The name people see: the Name field, else the host, or "localhost" for a socket.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        switch transport {
        case .socket: return "localhost"
        case .ssh: return ssh?.host ?? driverConfiguration.host
        case .tcp: return driverConfiguration.host
        case .sqlite: return fileURL?.lastPathComponent ?? "SQLite File"
        }
    }

    public struct DriverConfiguration: Sendable, Equatable {
        public var host: String
        public var port: Int
        /// Set for a socket connection; `host` and `port` are then unused.
        public var socketPath: String?
        public var user: String
        public var password: String?
        /// nil connects without a default database.
        public var database: String?

        /// "127.0.0.1:3306", or the socket's path.
        public var location: String { socketPath ?? "\(host):\(port)" }
    }

    /// Empty host means 127.0.0.1, empty port means 3306, empty socket means
    /// the first common socket that exists, empty database means none.
    public var driverConfiguration: DriverConfiguration {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedSocket = socket.trimmingCharacters(in: .whitespaces)
        let trimmedDatabase = database.trimmingCharacters(in: .whitespaces)
        return DriverConfiguration(
            host: trimmedHost.isEmpty ? Self.defaultHost : trimmedHost,
            port: Int(port.trimmingCharacters(in: .whitespaces)) ?? Self.defaultPort,
            socketPath: transport != .socket ? nil
                : trimmedSocket.isEmpty ? Self.defaultSocketPath() : (trimmedSocket as NSString).expandingTildeInPath,
            user: user.trimmingCharacters(in: .whitespaces),
            password: password.isEmpty ? nil : password,
            database: trimmedDatabase.isEmpty ? nil : trimmedDatabase)
    }

    /// A problem to show under the form before trying to connect, or nil.
    public var problem: String? {
        if transport == .sqlite { return fileURL == nil ? "Choose a SQLite file." : nil }
        if user.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a user name." }
        if let problem = ssl?.problem() { return problem }
        if transport == .socket { return nil }
        if transport == .ssh {
            if sshHost.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter an SSH host." }
            let trimmedSSHPort = sshPort.trimmingCharacters(in: .whitespaces)
            if !trimmedSSHPort.isEmpty, Int(trimmedSSHPort).map({ (1...65535).contains($0) }) != true {
                return "The SSH port must be a number from 1 to 65535."
            }
        }
        let trimmedPort = port.trimmingCharacters(in: .whitespaces)
        if !trimmedPort.isEmpty, Int(trimmedPort).map({ (1...65535).contains($0) }) != true {
            return "The port must be a number from 1 to 65535."
        }
        return nil
    }

    /// A saved connection's second line: "quarry@127.0.0.1:3399",
    /// "quarry@localhost (socket)", or "deploy@127.0.0.1:3306 via staging".
    public var summary: String {
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        let who = trimmedUser.isEmpty ? "" : trimmedUser + "@"
        let config = driverConfiguration
        switch transport {
        case .socket: return "\(who)localhost (socket)"
        case .tcp: return "\(who)\(config.host):\(config.port)"
        case .ssh: return "\(who)\(config.host):\(config.port) via \(ssh?.host ?? "")"
        case .sqlite: return ((fileURL?.path ?? "") as NSString).abbreviatingWithTildeInPath + (readOnly ? " · Read Only" : "")
        }
    }

    /// The SSH login for `.ssh`, with blanks filled in; nil for other transports.
    public var ssh: SSHTunnel.Login? {
        guard transport == .ssh else { return nil }
        let trimmedKey = sshKey.trimmingCharacters(in: .whitespaces)
        let trimmedUser = sshUser.trimmingCharacters(in: .whitespaces)
        return SSHTunnel.Login(
            host: sshHost.trimmingCharacters(in: .whitespaces),
            port: Int(sshPort.trimmingCharacters(in: .whitespaces)) ?? Self.defaultSSHPort,
            user: trimmedUser.isEmpty ? NSUserName() : trimmedUser,
            keyFile: trimmedKey.isEmpty ? nil : (trimmedKey as NSString).expandingTildeInPath,
            secret: sshPassword.isEmpty ? nil : sshPassword)
    }

    /// The SSL files when SSL is on, with blanks as nil and `~` expanded; nil when it is off.
    public var ssl: SSLOptions? {
        guard useSSL, transport != .sqlite else { return nil }
        func path(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath
        }
        return SSLOptions(keyFile: path(sslKey), certificateFile: path(sslCertificate), caFile: path(sslCA))
    }
}
