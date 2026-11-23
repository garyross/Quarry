import Foundation
import Observation
import QuarryKit

/// The User Accounts sheet (S-051): the server's accounts, edited in place
/// until Apply turns the difference into account statements.
@Observable
package final class UserManager: Identifiable {
    package enum Tab: String, CaseIterable, Identifiable {
        case general, global, schema, resources
        package var id: String { rawValue }
        package var title: String {
            switch self {
            case .general: "General"
            case .global: "Global Privileges"
            case .schema: "Schema Privileges"
            case .resources: "Resources"
            }
        }
    }

    package let id = UUID()
    /// The server's databases, for Schema Privileges.
    package let databases: [String]

    package private(set) var original: [UserAccount] = []
    package var accounts: [UserAccount] = []
    package var selection: UserAccount.ID?
    package var tab: Tab = .general
    /// The database Schema Privileges shows.
    package var schema: String?
    package private(set) var catalog = PrivilegeCatalog.all
    package private(set) var current: AccountName?
    package private(set) var isLoading = true
    package private(set) var isApplying = false
    package private(set) var loadError: DatabaseError?
    /// Statements the server refused on the last Apply; the sheet stays open to list them.
    package private(set) var failures: [AccountFailure] = []
    /// Apply with deleted accounts asks first.
    package var confirmingDelete = false

    package init(databases: [String]) {
        self.databases = databases
    }

    package func load(_ client: DatabaseClient) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await client.userAccounts()
            let selected = selectedAccount?.name
            original = list.accounts
            accounts = list.accounts
            catalog = list.catalog
            current = list.current
            loadError = nil
            selection = accounts.first { $0.name == selected }?.id
                ?? accounts.first { $0.name == list.current }?.id ?? accounts.first?.id
        } catch {
            loadError = DatabaseError.from(error)
        }
    }

    // MARK: Editing

    package var selectedAccount: UserAccount? {
        guard let selection else { return nil }
        return accounts.first { $0.id == selection }
    }

    /// Changes the selected account in place.
    package func edit(_ change: (inout UserAccount) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == selection }) else { return }
        change(&accounts[index])
    }

    package func isCurrent(_ account: UserAccount) -> Bool { account.original != nil && account.original == current }

    /// + under the list: "new_user@%", selected on General.
    package func addAccount() {
        var number = 1
        var name = AccountName(user: "new_user", host: "%")
        while accounts.contains(where: { $0.name == name }) {
            number += 1
            name.user = "new_user\(number)"
        }
        let account = UserAccount(name: name, original: nil, password: "")
        accounts.append(account)
        selection = account.id
        tab = .general
    }

    /// − under the list, or Delete. Nothing happens on the server until Apply.
    package func removeSelected() {
        guard let index = accounts.firstIndex(where: { $0.id == selection }) else { return }
        accounts.remove(at: index)
        selection = accounts.indices.contains(index) ? accounts[index].id : accounts.last?.id
    }

    package var canRemove: Bool { selectedAccount != nil && !isApplying }

    package func isGranted(_ privilege: Privilege) -> Bool { selectedAccount?.privileges.contains(privilege) ?? false }

    package func setGranted(_ privilege: Privilege, _ on: Bool) {
        edit { account in
            if on { account.privileges.insert(privilege) } else { account.privileges.remove(privilege) }
        }
    }

    /// Select All / Select None for one group of Global Privileges.
    package func setGranted(_ group: Privilege.Group, _ on: Bool) {
        let privileges = group.privileges.filter(catalog.global.contains)
        edit { account in
            if on { account.privileges.formUnion(privileges) } else { account.privileges.subtract(privileges) }
        }
    }

    // MARK: Schema Privileges

    /// The server's databases and every pattern an account holds, such as `test\_%`.
    package var schemaNames: [String] {
        let held = selectedAccount?.schemas.keys.map { $0 } ?? []
        return Array(Set(databases).union(held)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    package func schemaPrivileges(_ database: String) -> Set<Privilege> { selectedAccount?.schemas[database] ?? [] }

    package func isGranted(_ privilege: Privilege, on database: String) -> Bool { schemaPrivileges(database).contains(privilege) }

    package func setGranted(_ privileges: [Privilege], _ on: Bool, on database: String) {
        edit { account in
            var set = account.schemas[database] ?? []
            if on { set.formUnion(privileges) } else { set.subtract(privileges) }
            account.schemas[database] = set.isEmpty ? nil : set
        }
    }

    // MARK: Apply

    package var statements: [String] { AccountChanges.statements(from: original, to: accounts) }

    package var deletedAccounts: [AccountName] {
        let kept = Set(accounts.map(\.id))
        return original.filter { !kept.contains($0.id) }.map(\.name)
    }

    /// Why Apply cannot run: an empty user name or two accounts with one name.
    package var problem: String? {
        if accounts.contains(where: { $0.isNew && $0.name.user.isEmpty }) { return "A new account needs a user name." }
        var seen = Set<AccountName>()
        for account in accounts where !seen.insert(account.name).inserted {
            return "\(account.name.text) is listed twice."
        }
        return nil
    }

    package var canApply: Bool { !isLoading && !isApplying && loadError == nil && problem == nil && !statements.isEmpty }

    /// Runs the statements and reads the accounts back. True when the server took every one.
    package func apply(_ client: DatabaseClient) async -> Bool {
        guard canApply else { return false }
        isApplying = true
        defer { isApplying = false }
        failures = await client.applyAccountChanges(statements)
        await load(client)
        return failures.isEmpty
    }
}
