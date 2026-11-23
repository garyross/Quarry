import AppKit
import Foundation
import Observation
import QuarryKit

/// Quarry's MCP server (S-063): runs while Settings > MCP > Enable MCP Server
/// is on. Agents reach it two ways, both only from this Mac:
///   stdio  `Quarry.app/Contents/MacOS/Quarry mcp`, a bridge to a Unix socket only this user can open
///   HTTP   http://127.0.0.1:<port>/mcp with the token as Authorization: Bearer
/// Test runs (APP_STORE) never start it from the setting: the self-test starts it on a free port.
@MainActor @Observable
final class MCPHost {
    static let shared = MCPHost()

    enum Status: Equatable {
        case off
        case starting
        case running(port: Int)
        case failed(String)
    }

    private(set) var status: Status = .off
    /// Agents connected now: bridges on the socket, and HTTP sessions seen in the last 30 minutes.
    private(set) var clients: [MCPClient] = []
    /// Settings > MCP's token sheet (S-064); here so snapshots can open it.
    var tokenDraft: TokenDraft?
    /// Settings > MCP > Manual Setup… (S-066).
    var showingManualSetup = false

    @ObservationIgnored let tools = AgentTools()
    @ObservationIgnored private lazy var router = MCPRouter(serverVersion: Self.appVersion, instructions: AgentTools.instructions,
                                                            handler: tools)
    @ObservationIgnored private var listener: MCPListener?
    @ObservationIgnored private var socketClients: [UUID: MCPClient] = [:]
    @ObservationIgnored private var httpClients: [String: MCPClient] = [:]
    /// HTTP sessions the owner ended with Disconnect (S-065): their next request gets 404.
    @ObservationIgnored private var endedSessions: Set<String> = []
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var applying: Task<Void, Never>?
    @ObservationIgnored private var lastTried: Int?
    /// The self-test sets Ask before changes without touching the person's setting.
    @ObservationIgnored var askOverride: Bool?
    /// HTTP tokens by fingerprint (S-064), kept here so a request needn't read the Keychain.
    @ObservationIgnored private var tokenOwners: [String: UUID] = [:]

    // MARK: Settings

    static let enabledKey = "mcp.enabled"
    static let portKey = "mcp.port"
    /// S-063's switch; S-064 reads it once, as the Automatic token's first permission.
    static let allowChangesKey = "mcp.allowChanges"
    static let askKey = "mcp.askBeforeChanges"
    static let defaultPort = 53306
    static let portRange = 1024...65535

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var port: Int {
        let stored = UserDefaults.standard.integer(forKey: portKey)
        return portRange.contains(stored) ? stored : defaultPort
    }

    /// Ask before changes, on unless the person turned it off.
    var asksBeforeChanges: Bool {
        askOverride ?? (UserDefaults.standard.object(forKey: Self.askKey) as? Bool ?? true)
    }

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    /// Called by the first window: hands the tools the app's data and follows the setting.
    func configure(model: AppModel) {
        tools.model = model
        tools.asksBeforeChanges = { [weak self] in self?.asksBeforeChanges ?? true }
        tokensChanged()
        guard !configured else { return }
        configured = true
        guard !Store.isOverridden else { return }
        apply()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MCPHost.shared.apply() }
        }
    }

    /// Starts, stops or moves the server to match Settings. Defaults change
    /// for many reasons, so it does nothing when the server already matches,
    /// and doesn't retry a port that just failed.
    func apply() {
        let previous = applying
        applying = Task {
            await previous?.value
            let wanted: Int? = Self.enabled ? Self.port : nil
            if let wanted, wanted == port { return }
            if case .failed = status, wanted != nil, wanted == lastTried { return }
            if wanted == nil, listener == nil {
                if case .failed = status { status = .off }
                return
            }
            await stop()
            if let wanted {
                lastTried = wanted
                await start(port: wanted)
            }
        }
    }

    // MARK: Running

    /// Listens on 127.0.0.1:`port` (0 for any free port) and the Unix socket.
    func start(port: Int) async {
        guard listener == nil else { return }
        status = .starting
        let listener = MCPListener(
            tokens: currentTokens(),
            handle: { incoming in await MCPHost.shared.handle(incoming) },
            ended: { transport in await MCPHost.shared.ended(transport) })
        do {
            let bound = try await listener.listenHTTP(port: port)
            try await listener.listenSocket(path: Self.socketPath)
            self.listener = listener
            status = .running(port: bound)
        } catch {
            await listener.stop()
            status = .failed(Self.describe(error, port: port))
        }
    }

    func stop() async {
        guard let listener else {
            if case .failed = status { status = .off }
            return
        }
        self.listener = nil
        await listener.stop()
        unlink(Self.socketPath)
        socketClients = [:]
        httpClients = [:]
        clients = []
        await tools.connections.closeAll()
        status = .off
    }

    var port: Int? { if case .running(let port) = status { port } else { nil } }

    static func describe(_ error: any Error, port: Int) -> String {
        let text = "\(error)"
        if text.contains("Address already in use") || text.contains("EADDRINUSE") || text.contains("errno: 48") {
            return "Port \(port) is in use by another app. Choose another port."
        }
        return "Couldn’t start: \(text)"
    }

    /// The bridge's socket: next to the store, so a test run has its own.
    static var socketPath: String {
        if Store.isOverridden { return Store.url.path + ".mcp.sock" }
        return Store.url.deletingLastPathComponent().appending(path: "mcp.sock").path
    }

    // MARK: Messages

    func handle(_ incoming: MCPIncoming) async -> MCPOutgoing {
        let client: MCPClient
        var newSession: String?
        switch incoming.transport {
        case .socket(let id):
            if let known = socketClients[id] {
                client = known
            } else {
                client = MCPClient(transport: "stdio", tokenID: tools.model?.automaticToken?.uid)
                socketClients[id] = client
            }
        case .http(let session):
            if let session, endedSessions.contains(session) {
                return MCPOutgoing(body: MCPRouter.error(id: .null, code: -32001,
                    "Quarry disconnected this agent. Start a new session to connect again.").data, status: 404)
            }
            let tokenID = incoming.token.flatMap { tokenOwners[$0] }
            if let session, let known = httpClients[session], known.tokenID == tokenID {
                client = known
            } else {
                client = MCPClient(transport: "HTTP", tokenID: tokenID)
                let id = session ?? UUID().uuidString.lowercased()
                httpClients[id] = client
                if session == nil { newSession = id }
            }
        }
        refreshClients()
        let token = tools.model?.agentToken(client.tokenID)
        tools.model?.noteTokenUsed(client.tokenID)
        // A token deleted or revoked a moment ago reaches nothing.
        let access = token.flatMap { $0.revoked ? nil : $0.access } ?? AgentAccess(permission: .custom)
        let caller = AgentCaller(access: access, client: client.displayName, token: token?.name ?? "Deleted token",
                                 tokenID: client.tokenID, clientID: client.id)
        let reply = await AgentCaller.$current.withValue(caller) {
            await router.handle(incoming.body, client: client)
        }
        refreshClients()
        return MCPOutgoing(body: reply, session: newSession)
    }

    func ended(_ transport: MCPIncoming.Transport) {
        switch transport {
        case .socket(let id): socketClients[id] = nil
        case .http(let session): if let session { httpClients[session] = nil }
        }
        refreshClients()
    }

    private func refreshClients() {
        let recent = Date.now.addingTimeInterval(-30 * 60)
        httpClients = httpClients.filter { $0.value.lastActivity > recent }
        clients = (Array(socketClients.values) + Array(httpClients.values)).sorted { $0.started < $1.started }
    }

    /// "Running on 127.0.0.1:53306 · 2 agents connected".
    var statusText: String {
        switch status {
        case .off: "Off"
        case .starting: "Starting…"
        case .running(let port):
            "Running on 127.0.0.1:\(port) · " + (clients.isEmpty ? "No agents connected"
                : clients.count == 1 ? "1 agent connected" : "\(clients.count) agents connected")
        case .failed(let message): message
        }
    }

    // MARK: Connecting agents

    var endpoint: String { "http://127.0.0.1:\(port ?? Self.port)/mcp" }

    /// The command a stdio client runs: this app's own binary with `mcp`.
    static var bridgePath: String {
        Bundle.main.executableURL?.path ?? "/Applications/Quarry.app/Contents/MacOS/Quarry"
    }

    /// One line for Terminal that adds Quarry to Claude Code.
    static var claudeCommand: String {
        "claude mcp add --scope user quarry -- " + shellQuoted(bridgePath) + " mcp"
    }

    static func shellQuoted(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) } ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Tokens (S-064)

    /// S-063's single token, which S-064 keeps working as "HTTP Token".
    static let legacyTokenAccount = "mcp.token"

    /// The listener's map of HTTP token fingerprints to whether each works.
    private func currentTokens() -> [String: Bool] {
        guard let model = tools.model else { return [:] }
        let tokens = model.tokenFingerprints()
        tokenOwners = tokens.mapValues(\.uid)
        return tokens.mapValues { !$0.revoked }
    }

    /// Called whenever tokens change: the listener takes the new list at once.
    func tokensChanged() {
        let tokens = currentTokens()
        listener?.tokens = tokens
    }

    /// Ends every session that came with `token` (deleted or revoked).
    func disconnect(token: UUID) {
        httpClients = httpClients.filter { $0.value.tokenID != token }
        refreshClients()
    }

    /// MCP Activity's Disconnect (S-065): ends the agent's session and stops
    /// its running query. Its token still works, so it can connect again.
    func disconnect(client: MCPClient) async {
        if let (id, _) = socketClients.first(where: { $0.value === client }) {
            socketClients[id] = nil
            await listener?.close(socket: id)
        }
        for (session, known) in httpClients where known === client {
            httpClients[session] = nil
            endedSessions.insert(session)
        }
        refreshClients()
        await tools.connections.cancel(clientID: client.id)
    }

    /// The token name a client came with, for Connected Agents.
    func tokenName(_ client: MCPClient) -> String {
        tools.model?.agentToken(client.tokenID)?.name ?? "Deleted token"
    }
}
