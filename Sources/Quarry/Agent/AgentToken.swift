import Foundation
import QuarryKit
import SwiftData

/// A token agents use to reach the MCP server (S-064): a name, a permission,
/// and the connections it reaches. Its value is shown once; the Keychain keeps
/// only the fingerprint. The Automatic token is what stdio agents get.
@Model
final class AgentToken {
    var uid: UUID = UUID()
    var name: String = ""
    /// `AgentAccess` as JSON.
    var accessData: Data = Data()
    var revoked: Bool = false
    var automatic: Bool = false
    var createdAt: Date = Date.now
    var lastUsedAt: Date?

    init(name: String, access: AgentAccess, automatic: Bool = false) {
        self.name = name
        self.automatic = automatic
        self.access = access
    }

    var access: AgentAccess {
        get { (try? JSONDecoder().decode(AgentAccess.self, from: accessData)) ?? .readOnly }
        set { accessData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// "Used 5 minutes ago", "Never used".
    var lastUsedText: String {
        lastUsedAt.map { "Used " + $0.formatted(.relative(presentation: .named)) } ?? "Never used"
    }

    var keychainAccount: String { "mcp.token." + uid.uuidString }
}

extension AppModel {
    static let automaticTokenName = "Automatic"

    /// Every token, the Automatic one first, then by name. Makes the Automatic
    /// token the first time, with S-063's Allow changes as its permission, and
    /// keeps S-063's HTTP token working as "HTTP Token".
    func reloadAgentTokens() {
        let descriptor = FetchDescriptor<AgentToken>(sortBy: [SortDescriptor(\.name), SortDescriptor(\.createdAt)])
        var all = (try? context.fetch(descriptor)) ?? []
        if !all.contains(where: \.automatic) {
            let allowed = UserDefaults.standard.bool(forKey: MCPHost.allowChangesKey)
            let automatic = AgentToken(name: Self.automaticTokenName, access: allowed ? .readWrite : .readOnly, automatic: true)
            context.insert(automatic)
            if let old = PasswordStore.secret(MCPHost.legacyTokenAccount), !old.isEmpty {
                let http = AgentToken(name: "HTTP Token", access: allowed ? .readWrite : .readOnly)
                context.insert(http)
                PasswordStore.setSecret(AgentTokenValue.fingerprint(old), http.keychainAccount, label: "Quarry MCP token fingerprint")
                PasswordStore.removeSecret(MCPHost.legacyTokenAccount)
            }
            try? context.save()
            all = (try? context.fetch(descriptor)) ?? []
        }
        agentTokens = all.filter(\.automatic) + all.filter { !$0.automatic }
        MCPHost.shared.tokensChanged()
    }

    func agentToken(_ uid: UUID?) -> AgentToken? {
        agentTokens.first { $0.uid == uid }
    }

    var automaticToken: AgentToken? { agentTokens.first(where: \.automatic) }

    /// HTTP tokens by fingerprint, for the listener and for knowing whose a request is.
    func tokenFingerprints() -> [String: AgentToken] {
        var map: [String: AgentToken] = [:]
        for token in agentTokens where !token.automatic {
            if let fingerprint = PasswordStore.secret(token.keychainAccount) { map[fingerprint] = token }
        }
        return map
    }

    /// A new token; returns its value, the only time anyone sees it.
    @discardableResult
    func createAgentToken(name: String, access: AgentAccess) -> (token: AgentToken, value: String) {
        let value = AgentTokenValue.make()
        let token = AgentToken(name: name, access: access)
        context.insert(token)
        PasswordStore.setSecret(AgentTokenValue.fingerprint(value), token.keychainAccount, label: "Quarry MCP token fingerprint")
        try? context.save()
        reloadAgentTokens()
        return (token, value)
    }

    func updateAgentToken(_ token: AgentToken, name: String, access: AgentAccess) {
        if !token.automatic { token.name = name }
        token.access = access
        try? context.save()
        reloadAgentTokens()
    }

    func setRevoked(_ token: AgentToken, _ revoked: Bool) {
        guard !token.automatic else { return }
        token.revoked = revoked
        try? context.save()
        reloadAgentTokens()
        if revoked { MCPHost.shared.disconnect(token: token.uid) }
    }

    func deleteAgentToken(_ token: AgentToken) {
        guard !token.automatic else { return }
        let uid = token.uid
        PasswordStore.removeSecret(token.keychainAccount)
        context.delete(token)
        try? context.save()
        reloadAgentTokens()
        MCPHost.shared.disconnect(token: uid)
    }

    /// Notes a request, saving at most once a minute per token.
    func noteTokenUsed(_ uid: UUID?) {
        guard let token = agentToken(uid) else { return }
        if let last = token.lastUsedAt, Date.now.timeIntervalSince(last) < 60 { return }
        token.lastUsedAt = .now
        try? context.save()
    }
}
