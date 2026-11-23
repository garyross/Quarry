import AppKit
import Observation
import QuarryKit

/// Who is asking, for the length of one MCP request (S-064): the token's
/// access, and names for the approval sheet. MCPHost sets it per request.
struct AgentCaller: Sendable {
    var access: AgentAccess
    var client: String
    var token: String
    /// The token's uid and the MCPClient's id, for MCP Activity (S-065).
    var tokenID: UUID?
    var clientID: UUID?

    /// Outside a request (the self-test's direct calls): read only.
    @TaskLocal static var current = AgentCaller(access: .readOnly, client: "Quarry", token: "Automatic")
}

/// An agent's change waiting for the owner (S-064): Approve Agent Change.
@MainActor @Observable
final class AgentApproval: Identifiable {
    let id = UUID()
    let client: String
    let token: String
    let connection: String
    let database: String?
    let statement: String
    let deadline: Date
    @ObservationIgnored private var continuation: CheckedContinuation<Bool?, Never>?

    init(client: String, token: String, connection: String, database: String?, statement: String, deadline: Date) {
        self.client = client
        self.token = token
        self.connection = connection
        self.database = database
        self.statement = statement
        self.deadline = deadline
    }

    /// true Allow, false Deny, nil no answer in time. Only the first answer counts.
    func answer(_ allow: Bool?) {
        continuation?.resume(returning: allow)
        continuation = nil
    }

    fileprivate func wait() async -> Bool? {
        await withCheckedContinuation { continuation = $0 }
    }
}

/// Asks the owner before an agent's change runs, one question at a time.
@MainActor
enum AgentApprovals {
    /// How long a question waits before it counts as Deny. The self-test shortens it.
    static var timeout: TimeInterval = 120
    /// The question showing now (self-test).
    private(set) static weak var current: AgentApproval?
    private static var last: Task<Void, Never>?

    enum Outcome { case allowed, denied, timedOut }

    /// Shows Approve Agent Change in a window of `target`'s connection (or the
    /// front window, or a new one) and waits for the answer.
    static func ask(_ target: AgentConnections.Target, database: String?, statement: String) async -> Outcome {
        let caller = AgentCaller.current
        let previous = last
        let question = Task { () -> Outcome in
            await previous?.value
            let approval = AgentApproval(client: caller.client, token: caller.token, connection: target.name, database: database,
                                         statement: statement, deadline: .now.addingTimeInterval(timeout))
            present(approval, near: target)
            current = approval
            let timer = Task {
                try? await Task.sleep(for: .seconds(timeout))
                if !Task.isCancelled { approval.answer(nil) }
            }
            let answer = await approval.wait()
            timer.cancel()
            for session in Tabs.allSessions() where session.agentApproval === approval { session.agentApproval = nil }
            if current === approval { current = nil }
            switch answer {
            case true?: return .allowed
            case false?: return .denied
            case nil: return .timedOut
            }
        }
        last = Task { _ = await question.value }
        return await question.value
    }

    private static func present(_ approval: AgentApproval, near target: AgentConnections.Target) {
        NSApp.activate()
        let own = (target.session.map { [$0] } ?? []) + (target.savedUID.map { AgentConnections.windows(for: $0) } ?? [])
        let candidates = own + Tabs.connectedWindows().joined() + Tabs.allSessions()
        if let session = candidates.first(where: { $0.window?.attachedSheet == nil && $0.agentApproval == nil && $0.window != nil }) {
            session.window?.makeKeyAndOrderFront(nil)
            session.agentApproval = approval
        } else {
            // Every window is busy, or there is none: a new window asks.
            Tabs.open(beside: nil) { tab, _ in tab.agentApproval = approval }
        }
    }
}
