import AppKit
import QuarryKit

/// The connections agents use (S-063): one per server, separate from every
/// window's, so an agent's query never changes a window's database or session
/// and browsing never waits for it. Opened on first use, closed after ten idle
/// minutes, by close_connection, or when the MCP server stops.
///
/// A SQLite file gets two (S-073): reads on one opened read only with
/// `query_only`, so SQLite refuses any write itself, and write_query on its own.
@MainActor
final class AgentConnections {
    /// A connection an agent names: a saved connection, or a connected window that isn't saved.
    /// Saved ones carry no passwords until `client(for:)` connects.
    struct Target {
        /// The id agents pass back: the first 8 characters of the saved connection's
        /// uid, or "w-" and 8 of the window's.
        var id: String
        var name: String
        var details: ConnectionDetails
        var savedUID: UUID?
        /// The saved connection's group, for tokens limited to groups (S-064).
        var groupID: UUID?
        /// The connected window it came from, for its current database.
        weak var session: Session?
    }

    private struct Entry {
        var client: DatabaseClient
        var lastUsed: Date
    }

    private var open: [String: Entry] = [:]
    /// The connections each agent (MCPClient id) is running a query on now.
    private var running: [UUID: [UUID: DatabaseClient]] = [:]
    private var reaper: Task<Void, Never>?
    /// How long a query may run before it is stopped with KILL QUERY.
    static let timeout = 300
    static let idleMinutes = 10

    // MARK: Finding

    /// Every saved connection, and every connected window not opened from one,
    /// that the calling agent's token reaches (S-064).
    func targets(model: AppModel) -> [Target] {
        allTargets(model: model).filter { level($0) != .none }
    }

    /// What the calling agent's token may do on `target`.
    func level(_ target: Target) -> AgentAccess.Level {
        AgentCaller.current.access.level(connection: target.savedUID, group: target.groupID)
    }

    private func allTargets(model: AppModel) -> [Target] {
        let saved = model.savedConnections().map { connection in
            Target(id: Self.shortID(connection.uid), name: connection.displayName, details: connection.fields,
                   savedUID: connection.uid, groupID: connection.groupID, session: Self.windows(for: connection.uid).first)
        }
        let unsaved = Tabs.connectedWindows().joined().filter { $0.selectedSaved == nil }.compactMap { session -> Target? in
            guard let details = session.connectedDetails else { return nil }
            return Target(id: "w-" + Self.shortID(session.agentID), name: details.displayName, details: details,
                          savedUID: nil, session: session)
        }
        return saved + unsaved
    }

    /// Connected windows showing a saved connection.
    static func windows(for uid: UUID) -> [Session] {
        Tabs.connectedWindows().joined().filter { $0.selectedSaved == uid }
    }

    /// The connection `name` names (an id, or a whole name ignoring case), or
    /// with none, the frontmost connected window's.
    func target(_ name: String?, model: AppModel) throws -> Target {
        let wanted = (name ?? "").trimmingCharacters(in: .whitespaces)
        if wanted.isEmpty {
            guard let session = Tabs.connectedWindows().first?.first, let details = session.connectedDetails else {
                throw MCPToolError("No Quarry window is connected, so pass connection. Run list_connections to see them.")
            }
            let id = session.selectedSaved.map(Self.shortID) ?? "w-" + Self.shortID(session.agentID)
            let front = Target(id: id, name: details.displayName, details: details, savedUID: session.selectedSaved,
                               groupID: model.savedConnection(session.selectedSaved)?.groupID, session: session)
            guard level(front) != .none else {
                throw MCPToolError("This token can’t use the frontmost window’s connection, so pass connection. "
                    + "Run list_connections to see the ones it can use.", denied: true)
            }
            ActivityTrace.current?.connection = front.name
            return front
        }
        ActivityTrace.current?.connection = wanted
        let all = targets(model: model)
        let lower = wanted.lowercased()
        let byID = lower.count >= 4 ? all.filter { $0.id.hasPrefix(lower) || $0.savedUID?.uuidString.lowercased().hasPrefix(lower) == true } : []
        let byName = all.filter { $0.name.lowercased() == lower }
        let found = all.first { $0.id == lower } ?? (byID.count == 1 ? byID[0] : byName.count == 1 ? byName[0] : nil)
        if let found {
            ActivityTrace.current?.connection = found.name
            return found
        }
        if byID.count + byName.count > 1 {
            throw MCPToolError("More than one connection matches \u{201C}\(wanted)\u{201D}: "
                + (byID + byName).map { "\($0.name) (\($0.id))" }.joined(separator: ", ") + ". Pass its id.")
        }
        throw MCPToolError("No connection named \u{201C}\(wanted)\u{201D}. Run list_connections to see them.")
    }

    static func shortID(_ uid: UUID) -> String { String(uid.uuidString.lowercased().prefix(8)) }

    // MARK: Using

    func isOpen(_ id: String) -> Bool { open[id] != nil || open[id + Self.readSuffix] != nil }

    /// Marks the read-only connection to a SQLite file in `open`.
    private static let readSuffix = ":read"

    /// Where the connection for `target` is kept: a SQLite file's reads have their own.
    private func key(_ target: Target, writes: Bool) -> String {
        target.details.engine == .sqlite && !writes ? target.id + Self.readSuffix : target.id
    }

    /// The agent's connection to `target`, opened when there is none or it was lost.
    /// `writes` is for write_query; on a SQLite file everything else reads on a read-only connection.
    func client(for target: Target, writes: Bool = false) async throws -> DatabaseClient {
        let key = key(target, writes: writes)
        if let entry = open[key], !entry.client.isClosed, !(await entry.client.wasLost) {
            open[key]?.lastUsed = .now
            return entry.client
        }
        let readsFile = target.details.engine == .sqlite && !writes
        var details = target.details
        // Saved connections are listed without passwords; read them from the Keychain to connect.
        if let uid = target.savedUID, details.password.isEmpty { PasswordStore.fill(&details, from: uid) }
        // The Console names the connection, marked as the agent's.
        details.name = target.name + " (agent)"
        details.database = ""
        if readsFile { details.readOnly = true }
        let client: DatabaseClient
        do {
            client = try await DatabaseClient.connect(details)
            try await client.restrictForAgent(readOnly: readsFile)
        } catch is SSHQuestion {
            throw MCPToolError("Connecting to \(target.name) needs an answer in Quarry first (trust the SSH host, or a password). "
                + "Connect to it in Quarry once, then try again.")
        } catch {
            let problem = DatabaseError.from(error)
            // A file's own words already name it (S-068): "Can’t find “demo.sqlite”. It was moved or deleted."
            if target.details.engine == .sqlite {
                throw MCPToolError([problem.message, problem.suggestion].compactMap { $0 }.joined(separator: " "))
            }
            throw MCPToolError("Couldn’t connect to \(target.name): " + problem.message)
        }
        if let old = open[key]?.client { Task { await old.close() } }
        open[key] = Entry(client: client, lastUsed: .now)
        startReaper()
        return client
    }

    /// Runs `work` on the agent's connection, stopping it with KILL QUERY after `timeout` seconds.
    func run<T: Sendable>(_ target: Target, writes: Bool = false, timeout seconds: Int = timeout,
                          _ work: @escaping @Sendable (DatabaseClient) async throws -> T) async throws -> T {
        let key = key(target, writes: writes)
        let client = try await client(for: target, writes: writes)
        // S-065: Disconnect stops what this agent is running.
        let caller = AgentCaller.current.clientID
        let mark = UUID()
        if let caller { running[caller, default: [:]][mark] = client }
        defer { if let caller { running[caller]?[mark] = nil } }
        let stopped = TimeoutFlag()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            stopped.set()
            try? await client.cancelRunningQuery()
        }
        defer { watchdog.cancel() }
        do {
            let result = try await work(client)
            open[key]?.lastUsed = .now
            return result
        } catch {
            if stopped.isSet { throw MCPToolError("The query ran longer than \(seconds) seconds, so Quarry stopped it.") }
            if let mcp = error as? MCPToolError { throw mcp }
            throw MCPToolError(DatabaseError.from(error).message)
        }
    }

    /// Stops every query the agent `clientID` is running, with KILL QUERY (S-065).
    func cancel(clientID: UUID) async {
        for client in (running[clientID] ?? [:]).values { try? await client.cancelRunningQuery() }
    }

    /// Closes the agent's connection to `id`; false when there was none.
    @discardableResult
    func close(_ id: String) async -> Bool {
        let entries = [open.removeValue(forKey: id), open.removeValue(forKey: id + Self.readSuffix)].compactMap { $0 }
        for entry in entries { await entry.client.close() }
        return !entries.isEmpty
    }

    func closeAll() async {
        let all = open.values.map(\.client)
        open = [:]
        reaper?.cancel()
        reaper = nil
        for client in all { await client.close() }
    }

    private func startReaper() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                let limit = Date.now.addingTimeInterval(-Double(Self.idleMinutes * 60))
                for (key, entry) in open where entry.lastUsed < limit {
                    open[key] = nil
                    await entry.client.close()
                }
                if open.isEmpty { reaper = nil; return }
            }
        }
    }
}

/// Set once by the watchdog, read by the query that it stopped.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
