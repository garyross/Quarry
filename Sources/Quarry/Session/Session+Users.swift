import Foundation
import QuarryKit
import QuarryControllers

/// Database > User Accounts… (S-051).
extension Session {
    /// ⌘U: opens the sheet and reads the server's accounts.
    func requestUserAccounts() {
        guard phase == .connected, !isSQLite, let client, userManager == nil else { return }
        let manager = UserManager(databases: databases.filter { !client.dialect.isInMemory($0) })
        userManager = manager
        Task { await manager.load(client) }
    }

    /// Apply: deleted accounts ask first (`confirmApplyUserAccounts`).
    /// The returned task ends when the accounts have been read back (self-test).
    @discardableResult
    func applyUserAccounts() -> Task<Void, Never>? {
        guard let manager = userManager, manager.canApply else { return nil }
        if !manager.deletedAccounts.isEmpty, !manager.confirmingDelete {
            manager.confirmingDelete = true
            return nil
        }
        return confirmApplyUserAccounts()
    }

    /// Runs the changes; the sheet closes when the server took them all.
    @discardableResult
    func confirmApplyUserAccounts() -> Task<Void, Never>? {
        guard let client, let manager = userManager else { return nil }
        manager.confirmingDelete = false
        return Task {
            if await manager.apply(client), userManager === manager { userManager = nil }
        }
    }
}
