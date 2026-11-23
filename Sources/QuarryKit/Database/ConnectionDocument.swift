import CommonCrypto
import CryptoKit
import Foundation

/// A connection file (S-055): Sequel Pro's .spf, one connection and,
/// optionally, where its window was and its query text. A session file
/// (.quarrysession) holds one of these per tab, window by window.
///
/// Without passwords the file is plain and Sequel Pro opens it too. With
/// passwords, everything under `data` is encrypted with a file password:
/// Quarry writes AES-256-GCM with a PBKDF2-SHA256 key, and reads that or
/// Sequel Pro's own encryption (AES-128-CBC keyed by SHA-1, which it never writes).
public struct ConnectionDocument: Equatable, Sendable {
    /// One tab: how to connect and what it showed.
    public struct Tab: Equatable, Sendable {
        public var details: ConnectionDetails
        public var colorIndex: Int
        public var table: String?
        /// Sequel Pro's view name, such as SP_VIEW_CONTENT.
        public var view: String?
        public var query: String?

        public init(details: ConnectionDetails, colorIndex: Int = -1, table: String? = nil, view: String? = nil,
                    query: String? = nil) {
            self.details = details
            self.colorIndex = colorIndex
            self.table = table
            self.view = view
            self.query = query
        }
    }

    /// What Save puts in the file.
    public struct Options: Equatable, Sendable {
        public var connectsOnOpen = true
        /// Only with a file password; the passwords are then encrypted with it.
        public var includesPasswords = false
        public var includesQuery = false
        public var includesPlace = true

        public init(connectsOnOpen: Bool = true, includesPasswords: Bool = false, includesQuery: Bool = false,
                    includesPlace: Bool = true) {
            self.connectsOnOpen = connectsOnOpen
            self.includesPasswords = includesPasswords
            self.includesQuery = includesQuery
            self.includesPlace = includesPlace
        }
    }

    /// Windows, each a list of tabs; a connection file has one window with one tab.
    public var windows: [[Tab]]
    public var connectsOnOpen: Bool

    public init(windows: [[Tab]], connectsOnOpen: Bool) {
        self.windows = windows
        self.connectsOnOpen = connectsOnOpen
    }

    public var tabs: [Tab] { windows.flatMap { $0 } }

    public static let connectionExtension = "spf"
    public static let sessionExtension = "quarrysession"

    public enum FileError: LocalizedError, Equatable {
        case notAConnectionFile
        case needsPassword
        case wrongPassword
        case passwordRequired

        public var errorDescription: String? {
            switch self {
            case .notAConnectionFile: "This isn’t a connection file Quarry can read."
            case .needsPassword: "This file is encrypted. Enter its password to open it."
            case .wrongPassword: "That password doesn’t open this file."
            case .passwordRequired: "Saving passwords needs a file password to encrypt them with."
            }
        }
    }

    // MARK: Writing

    /// The file's bytes: an XML property list. `password` encrypts it, and is required when passwords are included.
    public func encoded(_ options: Options, password: String? = nil, asSession: Bool) throws -> Data {
        let password = password.flatMap { $0.isEmpty ? nil : $0 }
        if options.includesPasswords, password == nil { throw FileError.passwordRequired }
        let payload: [String: Any] = asSession
            ? ["windows": windows.map { ["tabs": $0.map { Self.tabData($0, options) }] }]
            : Self.tabData(tabs.first ?? Tab(details: ConnectionDetails()), options)
        var root: [String: Any] = [
            "version": 1,
            "format": asSession ? "quarry session" : "connection",
            "rdbms_type": "mysql",
            "auto_connect": options.connectsOnOpen,
            "encrypted": password != nil,
        ]
        if let password {
            let plain = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
            let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            root["encryption"] = Self.quarryScheme
            root["salt"] = salt
            root["rounds"] = Self.rounds
            root["data"] = try Self.seal(plain, password: password, salt: salt, rounds: Self.rounds)
        } else {
            root["data"] = payload
        }
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    /// Quarry's own connection type for a SQLite file (S-068); Sequel Pro had none.
    static let sqliteType = "QuarrySQLiteFile"

    static func tabData(_ tab: Tab, _ options: Options) -> [String: Any] {
        let d = tab.details
        let type = switch d.transport {
        case .tcp: "SPTCPIPConnection"
        case .socket: "SPSocketConnection"
        case .ssh: "SPSSHTunnelConnection"
        case .sqlite: Self.sqliteType
        }
        var connection: [String: Any] = [
            "name": d.name,
            "type": type,
            "rdbms_type": d.transport == .sqlite ? "sqlite" : "mysql",
            "host": d.transport == .socket ? "localhost" : d.host,
            "user": d.user,
            "useSSL": d.useSSL ? 1 : 0,
            "sslKeyFileLocationEnabled": d.sslKey.isEmpty ? 0 : 1,
            "sslKeyFileLocation": d.sslKey,
            "sslCertificateFileLocationEnabled": d.sslCertificate.isEmpty ? 0 : 1,
            "sslCertificateFileLocation": d.sslCertificate,
            "sslCACertFileLocationEnabled": d.sslCA.isEmpty ? 0 : 1,
            "sslCACertFileLocation": d.sslCA,
        ]
        if let port = Int(d.port) { connection["port"] = port }
        if !d.database.isEmpty { connection["database"] = d.database }
        if tab.colorIndex >= 0 { connection["colorIndex"] = tab.colorIndex }
        if d.transport == .socket, !d.socket.isEmpty { connection["socket"] = d.socket }
        if d.transport == .sqlite {
            connection["file"] = d.file
            connection["readOnly"] = d.readOnly ? 1 : 0
        }
        if d.transport == .ssh {
            connection["ssh_host"] = d.sshHost
            connection["ssh_user"] = d.sshUser
            connection["ssh_keyLocationEnabled"] = d.sshKey.isEmpty ? 0 : 1
            connection["ssh_keyLocation"] = d.sshKey
            if let port = Int(d.sshPort) { connection["ssh_port"] = port }
        }
        if options.includesPasswords {
            connection["password"] = d.password
            if d.transport == .ssh { connection["ssh_password"] = d.sshPassword }
        }
        var result: [String: Any] = ["connection": connection]
        var session: [String: Any] = [:]
        if options.includesPlace {
            if let table = tab.table { session["table"] = table }
            if let view = tab.view { session["view"] = view }
        }
        if options.includesQuery, let query = tab.query, !query.isEmpty { session["queries"] = query }
        if !session.isEmpty { result["session"] = session }
        return result
    }

    // MARK: Reading

    /// True when opening the file needs its password.
    public static func isEncrypted(_ data: Data) -> Bool {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return (root["encrypted"] as? NSNumber)?.boolValue ?? false
    }

    /// Reads a .spf (Quarry's or Sequel Pro's) or a .quarrysession file.
    public static func decode(_ data: Data, password: String? = nil) throws -> ConnectionDocument {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw FileError.notAConnectionFile
        }
        let connectsOnOpen = (root["auto_connect"] as? NSNumber)?.boolValue ?? false
        var payload: [String: Any]
        if (root["encrypted"] as? NSNumber)?.boolValue == true {
            guard let password, !password.isEmpty else { throw FileError.needsPassword }
            guard let sealed = root["data"] as? Data else { throw FileError.notAConnectionFile }
            if root["encryption"] as? String == quarryScheme {
                guard let salt = root["salt"] as? Data, let rounds = (root["rounds"] as? NSNumber)?.intValue,
                      let plain = try? open(sealed, password: password, salt: salt, rounds: rounds),
                      let dict = try? PropertyListSerialization.propertyList(from: plain, format: nil) as? [String: Any]
                else { throw FileError.wrongPassword }
                payload = dict
            } else {
                guard let dict = sequelProDecrypt(sealed, password: password) else { throw FileError.wrongPassword }
                payload = dict
            }
        } else {
            guard let dict = root["data"] as? [String: Any] else { throw FileError.notAConnectionFile }
            payload = dict
        }
        let windows: [[Tab]]
        if let list = payload["windows"] as? [[String: Any]] {
            windows = list.map { ($0["tabs"] as? [[String: Any]] ?? []).compactMap(tab) }.filter { !$0.isEmpty }
        } else if let one = tab(payload) {
            windows = [[one]]
        } else {
            windows = []
        }
        guard !windows.isEmpty else { throw FileError.notAConnectionFile }
        return ConnectionDocument(windows: windows, connectsOnOpen: connectsOnOpen)
    }

    static func tab(_ dict: [String: Any]) -> Tab? {
        guard let node = dict["connection"] as? [String: Any] else { return nil }
        func text(_ key: String) -> String {
            switch node[key] {
            case let value as String: value
            case let value as NSNumber: value.stringValue
            default: ""
            }
        }
        func flag(_ key: String) -> Bool { (node[key] as? NSNumber)?.boolValue ?? false }
        func file(_ key: String) -> String { flag(key + "Enabled") ? text(key) : "" }
        let transport: ConnectionDetails.Transport = switch text("type") {
        case "SPSocketConnection": .socket
        case "SPSSHTunnelConnection": .ssh
        case Self.sqliteType: .sqlite
        default: .tcp
        }
        let details = ConnectionDetails(
            name: text("name"), transport: transport, host: transport == .socket ? "" : text("host"),
            port: text("port"), socket: text("socket"), user: text("user"), password: text("password"),
            database: text("database"), sshHost: text("ssh_host"), sshPort: text("ssh_port"), sshUser: text("ssh_user"),
            sshPassword: text("ssh_password"), sshKey: file("ssh_keyLocation"), useSSL: flag("useSSL"),
            sslKey: file("sslKeyFileLocation"), sslCertificate: file("sslCertificateFileLocation"),
            sslCA: file("sslCACertFileLocation"), file: text("file"), readOnly: flag("readOnly"))
        let session = dict["session"] as? [String: Any]
        let query: String? = switch session?["queries"] {
        case let text as String: text
        default: nil
        }
        return Tab(details: details, colorIndex: (node["colorIndex"] as? NSNumber)?.intValue ?? -1,
                   table: session?["table"] as? String, view: session?["view"] as? String, query: query)
    }

    // MARK: Encryption

    static let quarryScheme = "AES-256-GCM PBKDF2-SHA256"
    static let rounds = 200_000

    static func key(_ password: String, salt: Data, rounds: Int) -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let secret = Array(password.utf8)
        _ = salt.withUnsafeBytes { saltBytes in
            secret.withUnsafeBufferPointer { passwordBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     passwordBytes.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                     secret.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &derived, derived.count)
            }
        }
        return SymmetricKey(data: derived)
    }

    static func seal(_ plain: Data, password: String, salt: Data, rounds: Int) throws -> Data {
        guard let combined = try AES.GCM.seal(plain, using: key(password, salt: salt, rounds: rounds)).combined else {
            throw FileError.notAConnectionFile
        }
        return combined
    }

    static func open(_ sealed: Data, password: String, salt: Data, rounds: Int) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key(password, salt: salt, rounds: rounds))
    }

    /// Sequel Pro's encrypted `data`: a 16-byte IV, then AES-128-CBC with the
    /// first 16 bytes of SHA-1(password) as the key; the plaintext's length is
    /// the last 4 bytes, big-endian. Inside is a keyed archive with the dictionary under "data".
    static func sequelProDecrypt(_ sealed: Data, password: String) -> [String: Any]? {
        guard sealed.count >= 32, sealed.count % 16 == 0 else { return nil }
        let key = Array(Insecure.SHA1.hash(data: Data(password.utf8)).prefix(16))
        let iv = Array(sealed.prefix(16))
        let body = Array(sealed.dropFirst(16))
        var out = [UInt8](repeating: 0, count: body.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), 0, key, key.count, iv,
                             body, body.count, &out, out.count, &moved)
        guard status == kCCSuccess, moved >= 4 else { return nil }
        let length = Int(out[moved - 4]) << 24 | Int(out[moved - 3]) << 16 | Int(out[moved - 2]) << 8 | Int(out[moved - 1])
        guard length <= moved - 4 else { return nil }
        let archive = Data(out.prefix(length))
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return nil }
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(forKey: "data") as? [String: Any]
    }
}

/// Sequel Pro's view names in a connection file's session, for Quarry's views.
public enum SavedView {
    public static let names = ["structure": "SP_VIEW_STRUCTURE", "content": "SP_VIEW_CONTENT", "query": "SP_VIEW_CUSTOMQUERY",
                               "info": "SP_VIEW_STATUS", "foreignKeys": "SP_VIEW_RELATIONS", "triggers": "SP_VIEW_TRIGGERS"]

    /// SP_VIEW_CONTENT for "content".
    public static func name(for view: String) -> String { names[view] ?? "SP_VIEW_STRUCTURE" }

    /// "content" for SP_VIEW_CONTENT; nil for a name Quarry doesn't know.
    public static func view(for name: String) -> String? { names.first { $0.value == name }?.key }
}
