import Foundation
import Testing
@testable import QuarryKit

struct UserAccountTests {
    private func account(_ user: String, host: String = "%", new: Bool = false, _ privileges: Set<Privilege> = [],
                         schemas: [String: Set<Privilege>] = [:]) -> UserAccount {
        let name = AccountName(user: user, host: host)
        return UserAccount(name: name, original: new ? nil : name, privileges: privileges, schemas: schemas)
    }

    @Test func noChangesNoStatements() {
        let old = [account("app", [.select, .insert], schemas: ["shop": [.update]])]
        #expect(AccountChanges.statements(from: old, to: old).isEmpty)
    }

    @Test func onlyTheDifferenceIsGrantedAndRevoked() {
        let old = account("app", [.select, .insert, .delete])
        var new = old
        new.privileges = [.select, .update, .alter]
        #expect(AccountChanges.statements(from: [old], to: [new]) == [
            "REVOKE INSERT, DELETE ON *.* FROM 'app'@'%'",
            "GRANT UPDATE, ALTER ON *.* TO 'app'@'%'",
        ])
    }

    @Test func grantOptionUsesItsOwnSyntax() {
        let old = account("app", [.select])
        var new = old
        new.privileges = [.select, .grantOption]
        #expect(AccountChanges.statements(from: [old], to: [new]) == ["GRANT USAGE ON *.* TO 'app'@'%' WITH GRANT OPTION"])
        new.privileges = [.select, .insert, .grantOption]
        #expect(AccountChanges.statements(from: [old], to: [new]) == ["GRANT INSERT ON *.* TO 'app'@'%' WITH GRANT OPTION"])
        #expect(AccountChanges.statements(from: [new], to: [old]) == ["REVOKE INSERT, GRANT OPTION ON *.* FROM 'app'@'%'"])
    }

    @Test func schemaPrivilegesPerDatabase() {
        let old = account("app", schemas: ["shop": [.select, .insert], "old`db": [.select]])
        var new = old
        new.schemas = ["shop": [.select, .update], "test\\_%": [.select]]
        #expect(AccountChanges.statements(from: [old], to: [new]) == [
            "REVOKE SELECT ON `old``db`.* FROM 'app'@'%'",
            "REVOKE INSERT ON `shop`.* FROM 'app'@'%'",
            "GRANT UPDATE ON `shop`.* TO 'app'@'%'",
            "GRANT SELECT ON `test\\_%`.* TO 'app'@'%'",
        ])
    }

    @Test func newAccountWithPasswordLimitsAndGrants() {
        var new = account("o'neil", host: "localhost", new: true, [.select], schemas: ["shop": [.insert]])
        new.password = "pa'ss"
        new.limits.maxQueries = 100
        new.limits.maxUserConnections = 2
        #expect(AccountChanges.statements(from: [], to: [new]) == [
            "CREATE USER 'o\\'neil'@'localhost' IDENTIFIED BY 'pa\\'ss' WITH MAX_QUERIES_PER_HOUR 100 MAX_USER_CONNECTIONS 2",
            "GRANT SELECT ON *.* TO 'o\\'neil'@'localhost'",
            "GRANT INSERT ON `shop`.* TO 'o\\'neil'@'localhost'",
        ])
    }

    @Test func renamePasswordLimitsAndDrop() {
        let keep = account("app", [.select])
        let gone = account("old", host: "10.0.0.%")
        var renamed = keep
        renamed.name = AccountName(user: "web", host: "localhost")
        renamed.password = ""
        renamed.limits.maxUpdates = 5
        #expect(AccountChanges.statements(from: [keep, gone], to: [renamed]) == [
            "DROP USER 'old'@'10.0.0.%'",
            "RENAME USER 'app'@'%' TO 'web'@'localhost'",
            "ALTER USER 'web'@'localhost' IDENTIFIED BY ''",
            "ALTER USER 'web'@'localhost' WITH MAX_UPDATES_PER_HOUR 5",
        ])
    }

    @Test func readsAccountsSkippingRolesAndStrangers() {
        let users = StatementResult(
            sql: "", columns: ["User", "Host", "Select_priv", "Grant_priv", "max_questions", "is_role"].map(column),
            rows: [["quarry", "%", "Y", "Y", "10", "N"], ["PUBLIC", "", "N", "N", "0", "Y"], ["", "localhost", "N", "N", "0", "N"]]
                .map { $0.map(CellValue.text) },
            affectedRows: nil, duration: .zero)
        let dbs = StatementResult(
            sql: "", columns: ["Host", "Db", "User", "Select_priv", "Insert_priv", "Grant_priv"].map(column),
            rows: [["%", "shop", "quarry", "Y", "N", "Y"], ["", "test", "PUBLIC", "Y", "Y", "N"], ["%", "none", "quarry", "N", "N", "N"]]
                .map { $0.map(CellValue.text) },
            affectedRows: nil, duration: .zero)
        let accounts = UserAccount.accounts(users: users, schemas: dbs)
        #expect(accounts.map(\.name.text) == ["Anonymous@localhost", "quarry@%"])
        #expect(accounts[1].privileges == [.select, .grantOption])
        #expect(accounts[1].schemas == ["shop": [.select, .grantOption]])
        #expect(accounts[1].limits.maxQueries == 10)
        let catalog = PrivilegeCatalog(users: users, schemas: dbs)
        #expect(catalog.global == [.select, .grantOption])
        #expect(catalog.schema == [.select, .insert, .grantOption])
    }

    @Test func titlesAndCurrentUser() {
        #expect(Privilege.createTemporaryTables.title == "Create Temporary Tables")
        #expect(Privilege.select.column == "Select_priv" && Privilege.showDatabases.column == "Show_db_priv")
        #expect(!Privilege.process.appliesToSchema && Privilege.grantOption.appliesToSchema)
        #expect(AccountName(currentUser: "quarry@127.0.0.1") == AccountName(user: "quarry", host: "127.0.0.1"))
        #expect(AccountName(currentUser: "a@b@%") == AccountName(user: "a@b", host: "%"))
    }

    private func column(_ name: String) -> ResultColumn { ResultColumn(name: name) }
}
