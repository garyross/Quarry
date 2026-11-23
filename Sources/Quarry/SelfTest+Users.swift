import AppKit
import QuarryKit

/// Self-test: User Accounts (S-051). Works only on accounts named quarry_selftest_*.
extension SelfTest {
    static func userAccounts(session: Session) async {
        guard let client = session.client else { return check("S-051 connected", false) }
        let first = AccountName(user: "quarry_selftest_user", host: "127.0.0.1")
        let moved = AccountName(user: "quarry_selftest_moved", host: "localhost")
        for name in [first, moved] { _ = try? await client.run("DROP USER IF EXISTS " + name.sql) }

        session.requestUserAccounts()
        guard let manager = session.userManager else { return check("S-051 ⌘U opens User Accounts", false) }
        await until { !manager.isLoading }
        for _ in 0..<50 where manager.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        check("S-051 the sheet lists the server's accounts and selects yours",
              manager.loadError == nil && manager.accounts.contains { $0.name.user == "quarry_reader" }
                  && manager.selectedAccount.map(manager.isCurrent) == true,
              manager.loadError?.message ?? "\(manager.accounts.count) accounts")
        check("S-051 roles are left out", !manager.accounts.contains { $0.name.user == "PUBLIC" })
        check("S-051 nothing changed, Apply is off", !manager.canApply && manager.statements.isEmpty)

        manager.addAccount()
        manager.edit { $0.name = first; $0.password = "s3cret" }
        manager.setGranted(.process, true)
        manager.setGranted([.select, .insert], true, on: "quarry_demo")
        manager.edit { $0.limits.maxQueries = 100 }
        manager.addAccount()
        manager.edit { $0.name = first }
        check("S-051 two accounts with one name are refused", manager.problem != nil && !manager.canApply)
        manager.removeSelected()
        await session.applyUserAccounts()?.value
        var grants = (try? await client.run("SHOW GRANTS FOR " + first.sql))?.rows.compactMap { $0.first?.plainText } ?? []
        check("S-051 Apply creates the account with its password, privileges and limit",
              session.userManager == nil
                  && grants.contains { $0.hasPrefix("GRANT PROCESS ON *.*") && $0.contains("MAX_QUERIES_PER_HOUR 100") }
                  && grants.contains { $0.hasPrefix("GRANT SELECT, INSERT ON `quarry_demo`.*") },
              grants.joined(separator: " | "))
        let login = try? await DatabaseClient.connect(ConnectionDetails(host: "127.0.0.1", port: "3399", user: first.user,
                                                                        password: "s3cret"))
        check("S-051 the new account logs in with its password", login != nil)
        await login?.close()

        // Rename, take one privilege away, and check only the difference is sent.
        session.requestUserAccounts()
        guard let again = session.userManager else { return check("S-051 the sheet opens again", false) }
        for _ in 0..<100 where again.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        again.selection = again.accounts.first { $0.name == first }?.id
        again.edit { $0.name = moved }
        again.setGranted([.insert], false, on: "quarry_demo")
        check("S-051 Apply sends only the rename and one REVOKE", again.statements == [
            "RENAME USER \(first.sql) TO \(moved.sql)", "REVOKE INSERT ON `quarry_demo`.* FROM \(moved.sql)",
        ], again.statements.joined(separator: "; "))
        await session.applyUserAccounts()?.value
        grants = (try? await client.run("SHOW GRANTS FOR " + moved.sql))?.rows.compactMap { $0.first?.plainText } ?? []
        check("S-051 the renamed account keeps the rest",
              grants.contains { $0.hasPrefix("GRANT SELECT ON `quarry_demo`.*") }, grants.joined(separator: " | "))

        // Delete asks first; Cancel in the alert sends nothing.
        session.requestUserAccounts()
        guard let last = session.userManager else { return check("S-051 the sheet opens a third time", false) }
        for _ in 0..<100 where last.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        last.selection = last.accounts.first { $0.name == moved }?.id
        last.removeSelected()
        let none = session.applyUserAccounts()
        check("S-051 deleting an account asks first", none == nil && last.confirmingDelete
              && last.deletedAccounts == [moved])
        await session.confirmApplyUserAccounts()?.value
        let left = try? await client.run("SELECT COUNT(*) AS n FROM mysql.user WHERE User LIKE 'quarry\\_selftest\\_%'")
        check("S-051 Delete and Apply drops it", left?.string(0, "n") == "0" && session.userManager == nil,
              left?.string(0, "n") ?? "")

        // A refused statement keeps the sheet open with the server's message.
        session.requestUserAccounts()
        guard let failing = session.userManager else { return }
        for _ in 0..<100 where failing.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        failing.addAccount()
        failing.edit { $0.name = first }
        failing.setGranted([.select], true, on: "quarry_demo")
        failing.edit { $0.schemas["no`such`db"] = [.alter]; $0.privileges = [.grantOption] }
        _ = try? await client.run("CREATE USER " + first.sql)
        await session.applyUserAccounts()?.value
        check("S-051 a refused statement stays in the sheet with the server's message",
              session.userManager === failing && failing.failures.first?.statement.hasPrefix("CREATE USER") == true,
              failing.failures.map(\.message).joined(separator: " | "))
        session.userManager = nil
        _ = try? await client.run("DROP USER IF EXISTS " + first.sql)
    }
}
