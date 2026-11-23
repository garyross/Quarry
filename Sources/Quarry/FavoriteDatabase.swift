import Foundation
import QuarryKit
import SwiftData

/// A database people starred (S-060). It belongs to a server and user, not to
/// a saved connection: it works from any connection to that server, survives
/// renaming or deleting connections, and opens on its own from the Connect
/// page. Its password is its own Keychain item under `uid`.
@Model
final class FavoriteDatabase {
    var uid: UUID = UUID()
    var database: String = ""
    /// `ConnectionDetails.Transport` raw value: "tcp" or "socket".
    var transport: String = "tcp"
    var host: String = ""
    var port: String = ""
    var socket: String = ""
    var user: String = ""
    /// SSH (S-047); the SSH password is in the Keychain.
    var sshHost: String = ""
    var sshPort: String = ""
    var sshUser: String = ""
    var sshKey: String = ""
    /// SSL (S-058): on or off, and the key, certificate and CA files.
    var useSSL: Bool = false
    var sslKey: String = ""
    var sslCertificate: String = ""
    var sslCA: String = ""
    var createdAt: Date = Date.now
    var lastUsedAt: Date?

    init(database: String, details: ConnectionDetails) {
        self.database = database
        transport = details.transport.rawValue
        host = details.host.trimmingCharacters(in: .whitespaces)
        port = details.port.trimmingCharacters(in: .whitespaces)
        socket = details.socket.trimmingCharacters(in: .whitespaces)
        user = details.user.trimmingCharacters(in: .whitespaces)
        sshHost = details.sshHost.trimmingCharacters(in: .whitespaces)
        sshPort = details.sshPort.trimmingCharacters(in: .whitespaces)
        sshUser = details.sshUser.trimmingCharacters(in: .whitespaces)
        sshKey = details.sshKey.trimmingCharacters(in: .whitespaces)
        useSSL = details.useSSL
        sslKey = details.sslKey.trimmingCharacters(in: .whitespaces)
        sslCertificate = details.sslCertificate.trimmingCharacters(in: .whitespaces)
        sslCA = details.sslCA.trimmingCharacters(in: .whitespaces)
    }

    /// The form's fields, without passwords.
    var fields: ConnectionDetails {
        ConnectionDetails(name: "", transport: kind, host: host, port: port, socket: socket, user: user,
                          database: database, sshHost: sshHost, sshPort: sshPort, sshUser: sshUser, sshKey: sshKey,
                          useSSL: useSSL, sslKey: sslKey, sslCertificate: sslCertificate, sslCA: sslCA)
    }

    var kind: ConnectionDetails.Transport { ConnectionDetails.Transport(rawValue: transport) ?? .tcp }

    /// The form's fields for opening this database. The passwords come from the Keychain.
    var details: ConnectionDetails {
        var details = fields
        PasswordStore.fill(&details, from: uid)
        return details
    }

    /// The server and user it belongs to (see `serverKey(for:)`).
    var serverKey: String { Self.serverKey(for: fields) }

    /// "quarry@127.0.0.1:3399", "quarry@localhost (socket)" or "… via staging".
    var summary: String { fields.summary }

    /// One server and user: the same for every connection that reaches them,
    /// whatever it is named. Default ports and blank hosts are filled in first.
    static func serverKey(for details: ConnectionDetails) -> String {
        // S-068: a SQLite file is its own server, so history and saved filters stay with the file.
        if let url = details.fileURL { return "sqlite:" + url.standardizedFileURL.path }
        let config = details.driverConfiguration
        var place = config.socketPath.map { "socket:" + $0 } ?? "tcp:\(config.host.lowercased()):\(config.port)"
        // Through SSH, 127.0.0.1 is the SSH host's own server.
        if let ssh = details.ssh { place = "ssh:\(ssh.user)@\(ssh.host.lowercased()):\(ssh.port)>" + place }
        return place + "|" + config.user
    }
}
