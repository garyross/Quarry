import Foundation
import QuarryKit

/// Database > Show Server Variables… (S-052).
extension Session {
    /// ⇧⌘V: opens the sheet and reads SHOW VARIABLES. The returned task ends when they are in (self-test).
    @discardableResult
    func requestServerVariables() -> Task<Void, Never>? {
        guard phase == .connected, !isSQLite, let client, serverVariables == nil, let details = connectedDetails else { return nil }
        let list = VariableList(server: details.displayName)
        serverVariables = list
        return Task { await list.load(client) }
    }
}
