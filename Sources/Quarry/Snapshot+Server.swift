import AppKit
import QuarryKit
import SwiftUI

/// Snapshot pages for user accounts, server variables and the MCP agent pages.
extension SnapshotPage {
    /// nil: not one of these pages. true: ready now. false: ready once the session's load ends.
    @MainActor
    func prepareServer(_ session: Session, model: AppModel, local: SavedConnection?) async -> Bool? {
        switch self {
        case .agentApproval:
            // S-064: an agent's UPDATE waiting for Allow or Deny.
            show(.content, "table:customers", in: session)
            await session.currentLoad?.value
            session.agentApproval = AgentApproval(
                client: "claude-code 2.1.0", token: "Automatic", connection: "Local", database: "quarry_demo",
                statement: "UPDATE customers\nSET status = 'inactive'\nWHERE last_order_at < '2025-01-01'",
                deadline: .now.addingTimeInterval(105))
        case .mcpActivity:
            // S-065: an agent's afternoon: reads, a change that was denied, an error.
            model.agentActivity = Self.sampleActivity()
            MCPActivityState.shared.page = .requests
            return true
        case .serverVariables:
            // S-052: filtered to "buffer", the count reading "N of M".
            session.view = .structure
            await session.requestServerVariables()?.value
            session.serverVariables?.search = "buffer"
        case .usersGeneral, .usersGlobal, .usersSchema, .usersResources:
            // S-051: the fixture's quarry_reader: PROCESS and SHOW DATABASES on the
            // server, SELECT and SHOW VIEW on quarry_demo, two limits.
            session.view = .structure
            session.requestUserAccounts()
            guard let manager = session.userManager else { break }
            for _ in 0..<100 where manager.isLoading {
                try? await Task.sleep(for: .milliseconds(20))
            }
            manager.selection = manager.accounts.first { $0.name.user == "quarry_reader" }?.id
            manager.schema = "quarry_demo"
            manager.tab = switch self {
            case .usersGlobal: .global
            case .usersSchema: .schema
            case .usersResources: .resources
            default: .general
            }
        default:
            return nil
        }
        return false
    }
}
