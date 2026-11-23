import Foundation

/// A saved connection's color tag (S-049): Sequel Pro's seven, in its order,
/// so a color index means the same thing in either app's files.
public enum ConnectionColor: Int, CaseIterable, Sendable, Identifiable {
    case red, orange, yellow, green, blue, purple, gray

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }

    /// The color for a stored index; -1 or an unknown index is no color.
    public init?(index: Int) {
        self.init(rawValue: index)
    }
}

/// How the Connect page orders saved connections and groups (S-049).
public enum ConnectionOrder: String, CaseIterable, Sendable, Identifiable {
    /// The order people dragged them into.
    case manual
    case name
    case host
    case type
    case color

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .manual: "Manual"
        case .name: "Name"
        case .host: "Host"
        case .type: "Type"
        case .color: "Color"
        }
    }

    /// One row to sort: what each key reads.
    public struct Item: Sendable, Equatable {
        public var name: String
        public var host: String
        public var transport: ConnectionDetails.Transport
        /// -1 for none; uncolored rows come last.
        public var colorIndex: Int
        public var order: Int

        public init(name: String, host: String, transport: ConnectionDetails.Transport, colorIndex: Int, order: Int) {
            self.name = name
            self.host = host
            self.transport = transport
            self.colorIndex = colorIndex
            self.order = order
        }
    }

    /// The indexes of `items` in this order, reversed when asked. Ties keep
    /// the manual order, so a sort is stable.
    public func sorted(_ items: [Item], reversed: Bool = false) -> [Int] {
        let indexes = items.indices.sorted { a, b in
            let x = items[a], y = items[b]
            if let before = precedes(x, y) { return before }
            return (x.order, a) < (y.order, b)
        }
        return reversed ? indexes.reversed() : indexes
    }

    /// Whether `x` comes before `y` by this key, or nil when they tie.
    private func precedes(_ x: Item, _ y: Item) -> Bool? {
        func compare(_ a: String, _ b: String) -> Bool? {
            let result = a.localizedStandardCompare(b)
            return result == .orderedSame ? nil : result == .orderedAscending
        }
        switch self {
        case .manual:
            return nil
        case .name:
            return compare(x.name, y.name)
        case .host:
            return compare(x.host, y.host) ?? compare(x.name, y.name)
        case .type:
            let rank = ConnectionDetails.Transport.allCases
            let a = rank.firstIndex(of: x.transport) ?? 0, b = rank.firstIndex(of: y.transport) ?? 0
            return a == b ? compare(x.name, y.name) : a < b
        case .color:
            let a = x.colorIndex < 0 ? Int.max : x.colorIndex, b = y.colorIndex < 0 ? Int.max : y.colorIndex
            return a == b ? compare(x.name, y.name) : a < b
        }
    }
}

/// Saved connections in a file (S-049): Sequel Pro's favorites export, an XML
/// property list read and written the same way, so either app opens the
/// other's file. Passwords are never in it.
public enum ConnectionFile {
    /// One connection in a file, with its group ("" for none) and color.
    public struct Entry: Equatable, Sendable {
        public var group: String
        /// The form's fields; passwords are always empty.
        public var details: ConnectionDetails
        public var colorIndex: Int

        public init(group: String = "", details: ConnectionDetails, colorIndex: Int = -1) {
            self.group = group
            var details = details
            details.password = ""
            details.sshPassword = ""
            self.details = details
            self.colorIndex = colorIndex
        }
    }

    public enum ImportError: Error, Equatable, LocalizedError {
        case noConnections

        public var errorDescription: String? {
            switch self {
            case .noConnections: "This file has no connections Quarry can read."
            }
        }
    }

    public static let fileExtension = "plist"
    static let rootKey = "SPConnectionFavorites"
    /// Sequel Pro's preferences file kept its favorites under this key.
    static let oldRootKey = "favorites"
    static let childrenKey = "Children"
    static let groupNameKey = "Name"
    static let expandedKey = "IsExpanded"

    /// Sequel Pro's connection types.
    static func typeNumber(_ transport: ConnectionDetails.Transport) -> Int {
        switch transport {
        case .tcp: 0
        case .socket: 1
        case .ssh: 2
        // Sequel Pro had no SQLite; Quarry's own number, with "file" and "readOnly" (S-068).
        case .sqlite: 3
        }
    }

    /// Groups first by `groups` order, each with its connections; ungrouped
    /// connections at the top level, as Sequel Pro writes them.
    public static func encode(_ entries: [Entry], groups: [String] = []) throws -> Data {
        var top: [Any] = entries.filter { $0.group.isEmpty }.map(dictionary)
        var names = groups.filter { !$0.isEmpty }
        for entry in entries where !entry.group.isEmpty && !names.contains(entry.group) { names.append(entry.group) }
        for name in names {
            let children = entries.filter { $0.group == name }.map(dictionary)
            top.append([groupNameKey: name, expandedKey: true, childrenKey: children] as [String: Any])
        }
        return try PropertyListSerialization.data(fromPropertyList: [rootKey: top], format: .xml, options: 0)
    }

    static func dictionary(_ entry: Entry) -> [String: Any] {
        let d = entry.details
        var result: [String: Any] = [
            "id": Int64.random(in: 1...Int64.max),
            "name": d.name,
            "type": typeNumber(d.transport),
            "host": d.host,
            "port": d.port,
            "user": d.user,
            "database": d.database,
            "socket": d.socket,
            "colorIndex": entry.colorIndex,
            "sshHost": d.sshHost,
            "sshPort": d.sshPort,
            "sshUser": d.sshUser,
            "sshKeyLocationEnabled": d.sshKey.isEmpty ? 0 : 1,
            "sshKeyLocation": d.sshKey,
            "useSSL": d.useSSL ? 1 : 0,
            "sslKeyFileLocationEnabled": d.sslKey.isEmpty ? 0 : 1,
            "sslKeyFileLocation": d.sslKey,
            "sslCertificateFileLocationEnabled": d.sslCertificate.isEmpty ? 0 : 1,
            "sslCertificateFileLocation": d.sslCertificate,
            "sslCACertFileLocationEnabled": d.sslCA.isEmpty ? 0 : 1,
            "sslCACertFileLocation": d.sslCA,
        ]
        if d.transport == .socket { result["host"] = "" }
        if d.transport == .sqlite {
            result["file"] = d.file
            result["readOnly"] = d.readOnly ? 1 : 0
        }
        return result
    }

    /// Every connection in the file, groups flattened ("Work / Clients"), and
    /// the group names in file order. Passwords in the file are ignored.
    public static func decode(_ data: Data) throws -> (entries: [Entry], groups: [String]) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let top = (plist[rootKey] ?? plist[oldRootKey]) as? [Any] else {
            throw ImportError.noConnections
        }
        var entries: [Entry] = []
        var groups: [String] = []
        func walk(_ nodes: [Any], group: String) {
            for case let node as [String: Any] in nodes {
                if let children = node[childrenKey] as? [Any] {
                    let name = (node[groupNameKey] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                    // Sequel Pro's root node is a group too: exported alone, "Favorites" holds the top level.
                    let isRoot = group.isEmpty && name == "Favorites" && top.count == 1
                    let path = isRoot || name.isEmpty ? group : (group.isEmpty ? name : "\(group) / \(name)")
                    if !path.isEmpty, !groups.contains(path) { groups.append(path) }
                    walk(children, group: path)
                } else if let entry = entry(node, group: group) {
                    entries.append(entry)
                }
            }
        }
        walk(top, group: "")
        guard !entries.isEmpty else { throw ImportError.noConnections }
        return (entries, groups)
    }

    static func entry(_ node: [String: Any], group: String) -> Entry? {
        func text(_ key: String) -> String {
            switch node[key] {
            case let value as String: value.trimmingCharacters(in: .whitespaces)
            case let value as NSNumber: value.stringValue
            default: ""
            }
        }
        func flag(_ key: String) -> Bool { (node[key] as? NSNumber)?.boolValue ?? false }
        func file(_ key: String) -> String { flag(key + "Enabled") ? text(key) : "" }
        guard node["name"] != nil || node["host"] != nil || node["socket"] != nil else { return nil }
        let transport: ConnectionDetails.Transport = switch (node["type"] as? NSNumber)?.intValue ?? 0 {
        case 1: .socket
        case 2: .ssh
        case 3: .sqlite
        default: .tcp
        }
        let details = ConnectionDetails(
            name: text("name"), transport: transport, host: transport == .socket ? "" : text("host"),
            port: text("port"), socket: text("socket"), user: text("user"), database: text("database"),
            sshHost: text("sshHost"), sshPort: text("sshPort"), sshUser: text("sshUser"),
            sshKey: file("sshKeyLocation"), useSSL: flag("useSSL"), sslKey: file("sslKeyFileLocation"),
            sslCertificate: file("sslCertificateFileLocation"), sslCA: file("sslCACertFileLocation"),
            file: text("file"), readOnly: flag("readOnly"))
        let color = (node["colorIndex"] as? NSNumber)?.intValue ?? -1
        return Entry(group: group, details: details, colorIndex: ConnectionColor(index: color) == nil ? -1 : color)
    }

    /// "Imported 3 connections in 1 group." for the alert.
    public static func summary(connections: Int, groups: Int) -> String {
        let count = connections == 1 ? "1 connection" : "\(connections) connections"
        guard groups > 0 else { return "Imported \(count)." }
        return "Imported \(count) in \(groups == 1 ? "1 group" : "\(groups) groups")."
    }

    /// "New Group", then "New Group 2", … past the names in use.
    public static func newGroupName(after used: [String]) -> String {
        let base = "New Group"
        if !used.contains(base) { return base }
        var number = 2
        while used.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// "Local Copy", then "Local Copy 2", … past the names in use.
    public static func copyName(of name: String, among used: [String]) -> String {
        let base = "\(name) Copy"
        if !used.contains(base) { return base }
        var number = 2
        while used.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}
