import Foundation
import Logging
import MySQLNIO
import NIOConcurrencyHelpers
import NIOCore
import NIOSSL

/// One MySQLNIO connection to a MySQL or MariaDB server, over TCP/IP, a Unix
/// socket, or an SSH tunnel (S-067). The only file that knows MySQLNIO.
final class MySQLDriver: SQLDriver, @unchecked Sendable {
    private let connection: MySQLConnection
    let serverVersion: String
    let connectionID: Int?
    let encryption: Encryption?
    private let configuration: ConnectionDetails.DriverConfiguration
    /// The SSH tunnel this connection goes through, given back on close (S-047).
    private let tunnel: NIOLockedValueBox<TunnelPool.Lease?>

    private init(connection: MySQLConnection, serverVersion: String, connectionID: Int?, encryption: Encryption?,
                 configuration: ConnectionDetails.DriverConfiguration, tunnel: TunnelPool.Lease?) {
        self.connection = connection
        self.serverVersion = serverVersion
        self.connectionID = connectionID
        self.encryption = encryption
        self.configuration = configuration
        self.tunnel = NIOLockedValueBox(tunnel)
    }

    /// Opens a connection. Throws `DatabaseError`, or `SSHQuestion` when SSH
    /// needs an answer first (S-047).
    static func connect(_ details: ConnectionDetails, timeout: Int) async throws -> MySQLDriver {
        let config = details.driverConfiguration
        // Read the SSL files before opening anything, so a bad file is its own error.
        let tls = try details.ssl?.tlsConfiguration()
        var tunnel: TunnelPool.Lease?
        if let login = details.ssh {
            tunnel = try await TunnelPool.shared.open(login, to: config.host, port: config.port)
        }
        do {
            let address = if let tunnel {
                try SocketAddress(unixDomainSocketPath: tunnel.socketPath)
            } else if let path = config.socketPath {
                try SocketAddress(unixDomainSocketPath: path)
            } else {
                try SocketAddress.makeAddressResolvingHost(config.host, port: config.port)
            }
            var logger = Logger(label: "app.quarry.mysql")
            logger.logLevel = .critical
            let connecting = MySQLConnection.connect(
                to: address,
                username: config.user,
                database: config.database ?? "",
                password: config.password,
                tlsConfiguration: tls,
                logger: logger,
                on: MultiThreadedEventLoopGroup.singleton.next()
            )
            let connection: MySQLConnection
            if let tunnel {
                let failuresBefore = await TunnelPool.shared.openFailures(tunnel)
                connection = try await handshake(connecting, timeout: .seconds(timeout),
                                                 message: "MySQL did not answer through the SSH host in time.",
                                                 suggestion: "Check MySQL Host and Port as the SSH host sees them, often 127.0.0.1 and 3306.") {
                    await TunnelPool.shared.openFailures(tunnel) > failuresBefore
                }
            } else {
                connection = try await handshake(connecting, timeout: .seconds(timeout),
                                                 message: "The server did not answer in \(timeout) seconds.",
                                                 suggestion: "Check the host and port, or allow longer in Settings > Network.") { false }
            }
            let version = try await connection.simpleQuery("SELECT VERSION()").get()
                .first.flatMap { $0.values.first ?? nil }.map { String(buffer: $0) } ?? ""
            let id = try await connection.simpleQuery("SELECT CONNECTION_ID()").get()
                .first.flatMap { $0.values.first ?? nil }.flatMap { Int(String(buffer: $0)) }
            var encryption: Encryption?
            if let ssl = details.ssl {
                // MySQLNIO quietly skips TLS when the server doesn't offer it; SSL on means encrypted or nothing.
                encryption = try await sessionEncryption(connection, serverChecked: ssl.checksServer)
                if encryption == nil {
                    try? await connection.close().get()
                    throw DatabaseError(message: "The server at \(config.location) does not offer SSL.",
                                        suggestion: "Turn off Use SSL, or turn on SSL on the server (ssl_cert and ssl_key).")
                }
            }
            // Text results as UTF-8 regardless of the server's default.
            _ = try await connection.simpleQuery("SET NAMES utf8mb4").get()
            return MySQLDriver(connection: connection, serverVersion: version, connectionID: id, encryption: encryption,
                               configuration: config, tunnel: tunnel)
        } catch {
            if let tunnel {
                await TunnelPool.shared.release(tunnel)
                // The tunnel is up, so a closed connection means the SSH host could not reach MySQL.
                if !(error is DatabaseError), (error as? MySQLError).map({ if case .server = $0 { false } else { true } }) ?? true {
                    throw DatabaseError(message: "The SSH host could not reach the MySQL server at \(config.host):\(config.port).",
                                        suggestion: "Check MySQL Host and Port as the SSH host sees them, often 127.0.0.1 and 3306.")
                }
            }
            throw DatabaseError.from(error, endpoint: config)
        }
    }

    /// The session's TLS version and cipher, or nil when it is not encrypted.
    private static func sessionEncryption(_ connection: MySQLConnection, serverChecked: Bool) async throws -> Encryption? {
        let rows = try await connection.simpleQuery("SHOW SESSION STATUS WHERE Variable_name IN ('Ssl_version', 'Ssl_cipher')").get()
        var status: [String: String] = [:]
        for row in rows where row.values.count >= 2 {
            if let name = row.values[0].map({ String(buffer: $0) }) {
                status[name.lowercased()] = row.values[1].map { String(buffer: $0) } ?? ""
            }
        }
        guard let cipher = status["ssl_cipher"], !cipher.isEmpty else { return nil }
        return Encryption(version: status["ssl_version"] ?? "", cipher: cipher, serverChecked: serverChecked)
    }

    /// Waits for a login through an SSH tunnel. When the SSH host cannot reach
    /// MySQL, `ssh` closes the forwarded connection but the handshake never
    /// fails, so this also stops when `gaveUp` says so, or after `timeout`. A
    /// login that finishes after that is closed.
    private static func handshake(_ connecting: EventLoopFuture<MySQLConnection>, timeout: Duration,
                                  message: String, suggestion: String,
                                  gaveUp: @Sendable () async -> Bool) async throws -> MySQLConnection {
        let box = HandshakeBox()
        connecting.whenComplete { box.finish($0) }
        let deadline = ContinuousClock.now + timeout
        while true {
            if let result = box.result { return try result.get() }
            if ContinuousClock.now > deadline || Task.isCancelled {
                box.abandon()
                throw DatabaseError(message: message, suggestion: suggestion)
            }
            if await gaveUp() {
                box.abandon()
                throw MySQLError.closed
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: SQLDriver

    var isClosed: Bool { connection.isClosed }

    func execute(_ sql: String, encoding: ViewEncoding) async throws -> (columns: [ResultColumn], rows: [[CellValue]]) {
        let rows = try await connection.simpleQuery(sql).get()
        let columns = rows.first.map { $0.columnDefinitions.map(Self.column) } ?? []
        let cells = rows.map { row in
            zip(row.values, row.columnDefinitions).map { Self.cell($0, $1, encoding) }
        }
        return (columns, cells)
    }

    func stream(_ sql: String, encoding: ViewEncoding,
                row: @escaping @Sendable (_ columns: () -> [ResultColumn], _ cells: () -> [CellValue]) -> Void) async throws {
        try await connection.simpleQuery(sql) { found in
            row({ found.columnDefinitions.map(Self.column) },
                { zip(found.values, found.columnDefinitions).map { Self.cell($0, $1, encoding) } })
        }.get()
    }

    func affectedRows() async throws -> Int {
        let count = try await connection.simpleQuery("SELECT ROW_COUNT()").get()
        return count.first.flatMap { $0.values.first ?? nil }.flatMap { Int(String(buffer: $0)) }.map { max(0, $0) } ?? 0
    }

    func lastInsertID() async throws -> UInt64 {
        let id = try await connection.simpleQuery("SELECT LAST_INSERT_ID()").get()
        return id.first.flatMap { $0.values.first ?? nil }.flatMap { UInt64(String(buffer: $0)) } ?? 0
    }

    func ping() async throws {
        _ = try await connection.simpleQuery("SELECT 1").get()
    }

    func close() async {
        try? await connection.close().get()
        let lease = tunnel.withLockedValue { lease in
            defer { lease = nil }
            return lease
        }
        if let lease { await TunnelPool.shared.release(lease) }
    }

    /// Server errors that mean the connection itself is gone, not the statement.
    /// 1927 connection killed (MariaDB), 2006 server has gone away, 2013 lost during query, 4031 idle timeout (MySQL 8).
    static let lostConnectionCodes: Set<Int> = [1927, 2006, 2013, 4031]

    func isLost(_ error: any Error) -> Bool {
        if connection.isClosed { return true }
        if let mysql = error as? MySQLError {
            switch mysql {
            case .closed: return true
            case .server(let packet): return Self.lostConnectionCodes.contains(Int(packet.errorCode.rawValue))
            default: break
            }
        }
        if let code = (error as? DatabaseError)?.code, Self.lostConnectionCodes.contains(code) { return true }
        let text = String(describing: error)
        return text.contains("ioOnClosedChannel") || text.contains("Connection reset") || text.contains("connection reset")
            || text.contains("Broken pipe")
    }

    func describe(_ error: any Error) -> DatabaseError { DatabaseError.from(error, endpoint: configuration) }

    // MARK: Decoding

    static func column(_ definition: MySQLProtocol.ColumnDefinition41) -> ResultColumn {
        let type = definition.columnType
        let binaryTypes: [MySQLProtocol.DataType] = [.blob, .tinyBlob, .mediumBlob, .longBlob, .string, .varString, .varchar]
        let isBinary = definition.characterSet == .binary && binaryTypes.contains(type)
        let numericTypes: [MySQLProtocol.DataType] = [.tiny, .short, .long, .longlong, .int24, .float, .double,
                                                      .decimal, .newdecimal, .bit, .year]
        return ResultColumn(name: definition.name, table: definition.orgTable,
                            database: definition.schema, orgName: definition.orgName, typeName: type.description, isBinary: isBinary,
                            isNumeric: numericTypes.contains(type),
                            isPrimaryKey: definition.flags.contains(.PRIMARY_KEY),
                            bitWidth: type == .bit ? BitValue.width(fromLength: String(definition.columnLength)) : nil)
    }

    static func cell(_ buffer: ByteBuffer?, _ definition: MySQLProtocol.ColumnDefinition41,
                     _ encoding: ViewEncoding = .utf8mb4) -> CellValue {
        guard var buffer else { return .null }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        let binaryTypes: [MySQLProtocol.DataType] = [.blob, .tinyBlob, .mediumBlob, .longBlob, .string, .varString, .varchar, .bit, .geometry]
        if definition.characterSet == .binary, binaryTypes.contains(definition.columnType) {
            // BINARY/VARBINARY that hold readable text still show as text.
            if definition.columnType != .bit, definition.columnType != .geometry,
               let text = String(validating: bytes, as: UTF8.self), !text.contains(where: { $0.isASCII && $0.asciiValue! < 9 }) {
                return .text(text)
            }
            return .binary(Data(bytes))
        }
        if let text = encoding.decode(bytes) { return .text(text) }
        return .binary(Data(bytes))
    }
}

extension DatabaseError {
    /// Maps driver and network errors to messages people can act on.
    /// `endpoint` names the server in network errors.
    public static func from(_ error: any Error, endpoint: ConnectionDetails.DriverConfiguration? = nil) -> DatabaseError {
        if let error = error as? DatabaseError { return error }
        if let mysql = error as? MySQLError {
            switch mysql {
            case .server(let packet):
                let code = Int(packet.errorCode.rawValue)
                return DatabaseError(message: packet.errorMessage, code: code,
                                     suggestion: code == 1045 ? "Check the user name and password." : nil)
            case .invalidSyntax(let message):
                // MySQLNIO adds "Invalid syntax: "; show the server's words only.
                return DatabaseError(message: message, code: 1064)
            case .duplicateEntry(let message):
                return DatabaseError(message: message, code: 1062)
            case .closed:
                return DatabaseError(message: "The connection to the server was closed.",
                                     suggestion: "Reconnect and try again.")
            default:
                return DatabaseError(message: mysql.message)
            }
        }
        let text = String(describing: error)
        if error is NIOSSLError || text.contains("BoringSSL") || text.contains("handshakeFailed") {
            let place = endpoint?.location ?? "the server"
            if text.uppercased().contains("CERTIFICATE_VERIFY_FAILED") {
                return DatabaseError(message: "The certificate of \(place) is not signed by the CA certificate.",
                                     suggestion: "Choose the CA certificate that signed the server's certificate, or leave CA Certificate empty.")
            }
            return DatabaseError(message: "The SSL handshake with \(place) failed.",
                                 suggestion: "Check the SSL files, or turn off Use SSL.")
        }
        if let path = endpoint?.socketPath {
            if text.contains("PathTooLong") {
                return DatabaseError(message: "The socket path is too long: \(path).",
                                     suggestion: "Use a path under 104 characters.")
            }
            if text.contains("No such file") || text.contains("ENOENT") || text.contains("errno: 2)") {
                return DatabaseError(message: "There is no socket at \(path).",
                                     suggestion: "Check that the server is running and the socket path is right.")
            }
            if text.contains("Connection refused") || text.contains("connectFailed") || text.contains("NIOConnectionError")
                || text.contains("connectTimeout") {
                return DatabaseError(message: "Could not reach the socket at \(path).",
                                     suggestion: "Check that the server is running and the socket path is right.")
            }
            if text.contains("Permission denied") || text.contains("EACCES") {
                return DatabaseError(message: "Quarry may not open the socket at \(path).",
                                     suggestion: "Check the file's permissions.")
            }
        }
        let host = endpoint?.host ?? ""
        let port = endpoint?.port ?? 0
        if text.contains("connectTimeout") || text.contains("Connection refused") || text.contains("connection reset")
            || text.contains("NIOConnectionError") || text.contains("connectFailed") {
            return DatabaseError(message: "Could not reach \(host):\(port).",
                                 suggestion: "Check that the server is running and the host and port are right.")
        }
        if text.contains("NoAddress") || text.contains("unknownHost") || text.contains("getaddrinfo") {
            return DatabaseError(message: "Could not find the host \"\(host)\".",
                                 suggestion: "Check the host name.")
        }
        return DatabaseError(message: error.localizedDescription)
    }
}

/// The result of a handshake `MySQLDriver.handshake` waits for; a login
/// that finishes after it gave up is closed.
private final class HandshakeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished: Result<MySQLConnection, any Error>?
    private var abandoned = false

    var result: Result<MySQLConnection, any Error>? { lock.withLock { finished } }

    func finish(_ result: Result<MySQLConnection, any Error>) {
        let late = lock.withLock {
            finished = result
            return abandoned
        }
        if late, case .success(let connection) = result { _ = connection.close() }
    }

    func abandon() {
        let open = lock.withLock {
            abandoned = true
            return finished
        }
        if case .success(let connection) = open { _ = connection.close() }
    }
}
