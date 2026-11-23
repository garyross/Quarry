import Foundation

/// The server's accounts for the User Accounts sheet (S-051).
public struct AccountList: Sendable {
    public var accounts: [UserAccount]
    public var catalog: PrivilegeCatalog
    /// The account this connection logged in as (CURRENT_USER()).
    public var current: AccountName?
}

/// A statement Apply sent that the server refused.
public struct AccountFailure: Sendable, Hashable, Identifiable {
    public var statement: String
    public var message: String
    public var id: String { statement }
}

extension DatabaseClient {
    /// Reads mysql.user and mysql.db. An account without SELECT on them gets the server's error.
    public func userAccounts() async throws -> AccountList {
        let users = try await run("SELECT * FROM mysql.user")
        let schemas = try await run("SELECT * FROM mysql.db")
        let current = try await run("SELECT CURRENT_USER() AS u").string(0, "u").flatMap(AccountName.init(currentUser:))
        return AccountList(accounts: UserAccount.accounts(users: users, schemas: schemas),
                           catalog: PrivilegeCatalog(users: users, schemas: schemas), current: current)
    }

    /// Runs every statement, in order, and returns the ones the server refused.
    /// It keeps going after a failure, so one bad account does not stop the others.
    public func applyAccountChanges(_ statements: [String]) async -> [AccountFailure] {
        var failures: [AccountFailure] = []
        for statement in statements {
            do {
                _ = try await run(statement)
            } catch {
                failures.append(AccountFailure(statement: statement, message: DatabaseError.from(error).message))
            }
        }
        return failures
    }
}
