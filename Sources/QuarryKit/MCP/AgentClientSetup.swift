import Foundation

/// An MCP client Quarry can add itself to (S-066).
public enum AgentClient: String, CaseIterable, Sendable, Identifiable {
    case claudeCode, codex, cursor, claudeDesktop

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .claudeDesktop: "Claude Desktop"
        }
    }

    /// The config file, relative to the home folder.
    public var configPath: String {
        switch self {
        case .claudeCode: ".claude.json"
        case .codex: ".codex/config.toml"
        case .cursor: ".cursor/mcp.json"
        case .claudeDesktop: "Library/Application Support/Claude/claude_desktop_config.json"
        }
    }

    /// Paths, relative to home, whose presence means the client is on this Mac.
    var markers: [String] {
        switch self {
        case .claudeCode: [".claude.json", ".claude"]
        case .codex: [".codex"]
        case .cursor: [".cursor"]
        case .claudeDesktop: ["Library/Application Support/Claude"]
        }
    }

    var isTOML: Bool { self == .codex }

    /// What the owner does after Add for the client to see Quarry.
    public var nextStep: String {
        switch self {
        case .claudeCode: "Start a new Claude Code session to use it."
        case .codex: "Start a new Codex session to use it."
        case .cursor: "Cursor turns it on in Settings > MCP."
        case .claudeDesktop: "Quit and reopen Claude Desktop to use it."
        }
    }
}

/// Where a client stands with Quarry.
public enum AgentSetupState: Equatable, Sendable {
    case notFound
    case absent
    case added
    /// A `quarry` entry whose command is another path.
    case otherCopy(String)
    /// The file exists but can't be parsed; it is never rewritten.
    case unreadable
}

public enum AgentSetupError: LocalizedError, Equatable {
    case unreadable(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let file): "\(file) isn’t valid, so Quarry left it alone. Fix it, or use Manual Setup…"
        case .notFound(let client): "\(client) isn’t on this Mac."
        }
    }
}

/// Reads and writes clients' MCP config files under one home folder. The app uses the real home;
/// the self-test passes a temporary one.
public struct AgentSetup: Sendable {
    public static let serverName = "quarry"
    public static let backupSuffix = ".quarry-backup"
    public let home: URL
    public let bridge: String

    public init(home: URL, bridge: String) {
        self.home = home
        self.bridge = bridge
    }

    public func url(_ client: AgentClient) -> URL { home.appending(path: client.configPath) }

    /// The path as the owner reads it, with ~ for home.
    public static func displayPath(_ client: AgentClient) -> String { "~/" + client.configPath }

    public func state(_ client: AgentClient) -> AgentSetupState {
        let fm = FileManager.default
        let file = url(client)
        guard let data = fm.contents(atPath: file.path) else {
            return client.markers.contains { fm.fileExists(atPath: home.appending(path: $0).path) } ? .absent : .notFound
        }
        let command: String?
        if client.isTOML {
            guard let text = String(data: data, encoding: .utf8) else { return .unreadable }
            command = AgentConfigEdit.tomlCommand(text)
        } else {
            // Not `try?`: it would flatten "no entry" (nil) into "can't read".
            do { command = try AgentConfigEdit.jsonCommand(data) } catch { return .unreadable }
        }
        guard let command else { return .absent }
        return command == bridge ? .added : .otherCopy(command)
    }

    /// Adds Quarry, or points an existing entry at this copy.
    public func add(_ client: AgentClient) throws {
        try change(client) { data in
            if client.isTOML {
                return Data(AgentConfigEdit.tomlAdding(String(decoding: data, as: UTF8.self), bridge: bridge).utf8)
            }
            return try AgentConfigEdit.jsonAdding(data, entry: AgentConfigEdit.entry(for: client, bridge: bridge))
        }
    }

    public func remove(_ client: AgentClient) throws {
        try change(client) { data in
            if client.isTOML { return Data(AgentConfigEdit.tomlRemoving(String(decoding: data, as: UTF8.self)).utf8) }
            return try AgentConfigEdit.jsonRemoving(data)
        }
    }

    /// Backs up the file, writes the edit atomically and keeps the file's permissions.
    private func change(_ client: AgentClient, _ edit: (Data) throws -> Data) throws {
        let fm = FileManager.default
        let file = url(client)
        switch state(client) {
        case .notFound: throw AgentSetupError.notFound(client.name)
        case .unreadable: throw AgentSetupError.unreadable(Self.displayPath(client))
        default: break
        }
        let old = fm.contents(atPath: file.path)
        let attributes = old == nil ? nil : try? fm.attributesOfItem(atPath: file.path)
        let new: Data
        do { new = try edit(old ?? Data()) } catch { throw AgentSetupError.unreadable(Self.displayPath(client)) }
        if let old {
            let backup = URL(filePath: file.path + Self.backupSuffix)
            try old.write(to: backup, options: .atomic)
            if let mode = attributes?[.posixPermissions] { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: backup.path) }
        } else {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try new.write(to: file, options: .atomic)
        if let mode = attributes?[.posixPermissions] { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
    }
}

/// The edits themselves, on file contents: pure, so unit tests cover them.
public enum AgentConfigEdit {
    /// The `quarry` server entry a JSON client gets.
    public static func entry(for client: AgentClient, bridge: String) -> [String: Any] {
        var entry: [String: Any] = ["command": bridge, "args": ["mcp"]]
        if client == .claudeCode {
            entry["type"] = "stdio"
            entry["env"] = [String: Any]()
        }
        return entry
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentSetupError.unreadable("JSON")
        }
        return object
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        data.append(0x0A)
        return data
    }

    /// The `quarry` server's command, nil when there is none; throws when the file isn't a JSON object.
    public static func jsonCommand(_ data: Data) throws -> String? {
        let servers = try object(data)["mcpServers"] as? [String: Any]
        guard let entry = servers?[AgentSetup.serverName] as? [String: Any] else { return nil }
        return entry["command"] as? String ?? ""
    }

    public static func jsonAdding(_ data: Data, entry: [String: Any]) throws -> Data {
        var root = try object(data)
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[AgentSetup.serverName] = entry
        root["mcpServers"] = servers
        return try encode(root)
    }

    public static func jsonRemoving(_ data: Data) throws -> Data {
        var root = try object(data)
        guard var servers = root["mcpServers"] as? [String: Any] else { return data }
        servers[AgentSetup.serverName] = nil
        root["mcpServers"] = servers
        return try encode(root)
    }

    // MARK: TOML (Codex): only the `[mcp_servers.quarry]` table and its subtables are touched, line by line.

    private static let tables = ["mcp_servers.quarry", "mcp_servers.\"quarry\"", "mcp_servers.'quarry'"]

    /// The table name in a `[header]` line, nil for any other line.
    private static func header(_ line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.lastIndex(of: "]") else { return nil }
        return trimmed[trimmed.startIndex..<close].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
    }

    private static func isQuarry(_ name: String) -> Bool {
        tables.contains { name == $0 || name.hasPrefix($0 + ".") }
    }

    /// The file's lines split into what stays and the line where the quarry table was (or nil).
    private static func without(_ text: String) -> (lines: [Substring], at: Int?) {
        var kept: [Substring] = []
        var inside = false
        var at: Int?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let name = header(line) {
                inside = isQuarry(name)
                if inside, at == nil { at = kept.count }
            }
            if !inside { kept.append(line) }
        }
        return (kept, at)
    }

    public static func tomlCommand(_ text: String) -> String? {
        var inside = false
        var found = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let name = header(line) {
                inside = tables.contains(name)
                found = found || inside
                continue
            }
            guard inside else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "command" else { continue }
            return unquote(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return found ? "" : nil
    }

    private static func unquote(_ value: String) -> String {
        if value.hasPrefix("'"), value.count >= 2 { return String(value.dropFirst().prefix { $0 != "'" }) }
        guard value.hasPrefix("\"") else { return value }
        var result = ""
        var escaped = false
        for character in value.dropFirst() {
            if escaped { result.append(character); escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { break } else { result.append(character) }
        }
        return result
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func tomlAdding(_ text: String, bridge: String) -> String {
        var (lines, at) = without(text)
        let table: [Substring] = ["[mcp_servers.quarry]", Substring("command = " + quoted(bridge)), "args = [\"mcp\"]", ""]
        if let at {
            lines.insert(contentsOf: table, at: at)
        } else {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines += table
        }
        return lines.joined(separator: "\n")
    }

    public static func tomlRemoving(_ text: String) -> String {
        without(text).lines.joined(separator: "\n")
    }
}
