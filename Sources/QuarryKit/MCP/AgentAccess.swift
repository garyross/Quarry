import CryptoKit
import Foundation
import Security

/// What one agent token may do (S-064): read or change, on every connection,
/// on chosen connections and groups, or per connection (Custom).
public struct AgentAccess: Codable, Equatable, Sendable {
    /// What a token may do on one connection.
    public enum Level: String, Codable, CaseIterable, Sendable, Comparable {
        case none, read, write

        public var title: String {
            switch self {
            case .none: "No Access"
            case .read: "Read Only"
            case .write: "Read & Write"
            }
        }

        public static func < (a: Level, b: Level) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public enum Permission: String, Codable, CaseIterable, Sendable {
        case readOnly, readWrite, custom

        public var title: String {
            switch self {
            case .readOnly: "Read Only"
            case .readWrite: "Read & Write"
            case .custom: "Custom"
            }
        }
    }

    public var permission: Permission
    /// Read Only and Read & Write: every connection, or only `connections` and those in `groups`.
    public var allConnections: Bool
    public var connections: Set<UUID>
    public var groups: Set<UUID>
    /// Custom: each saved connection's level; those missing have no access.
    public var custom: [UUID: Level]

    public init(permission: Permission = .readOnly, allConnections: Bool = true, connections: Set<UUID> = [],
                groups: Set<UUID> = [], custom: [UUID: Level] = [:]) {
        self.permission = permission
        self.allConnections = allConnections
        self.connections = connections
        self.groups = groups
        self.custom = custom
    }

    public static let readOnly = AgentAccess()
    public static let readWrite = AgentAccess(permission: .readWrite)

    /// The level on a connection: a saved one (its uid and group), or with no
    /// uid a connected window that isn't saved, which only "All Connections" reaches.
    public func level(connection: UUID?, group: UUID?) -> Level {
        switch permission {
        case .custom:
            return connection.flatMap { custom[$0] } ?? .none
        case .readOnly, .readWrite:
            let reaches = allConnections
                || connection.map(connections.contains) == true
                || group.map(groups.contains) == true
            guard reaches else { return .none }
            return permission == .readWrite ? .write : .read
        }
    }

    /// "Read Only · All Connections", "Read & Write · 2 connections, 1 group", "Custom · 3 connections".
    public var summary: String {
        switch permission {
        case .custom:
            let count = custom.values.filter { $0 != .none }.count
            return "Custom · " + Self.count(count, "connection")
        case .readOnly, .readWrite:
            if allConnections { return permission.title + " · All Connections" }
            let parts = [connections.isEmpty ? nil : Self.count(connections.count, "connection"),
                         groups.isEmpty ? nil : Self.count(groups.count, "group")].compactMap { $0 }
            return permission.title + " · " + (parts.isEmpty ? "No connections" : parts.joined(separator: ", "))
        }
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

/// Token values and their fingerprints (S-064). Quarry shows a value once and keeps only its SHA-256.
public enum AgentTokenValue {
    /// A random 256-bit token, URL-safe base64 without padding, prefixed "qmcp_" so people can tell what it is.
    public static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "qmcp_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The hex SHA-256 of a value, what the Keychain and the listener keep.
    public static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
