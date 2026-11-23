import QuarryKit
import QuarryControllers
import SwiftUI

/// Database > User Accounts… (⌘U, S-051): the server's accounts on the left,
/// the selected one's General, Global Privileges, Schema Privileges and
/// Resources on the right. Nothing reaches the server until Apply, which
/// sends only what changed and asks first when accounts are deleted.
struct UserAccountsSheet: View {
    @Bindable var manager: UserManager
    let apply: () -> Void
    let confirmDelete: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("User Accounts")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding([.horizontal, .top], Space.margin)
                .padding(.bottom, Space.md)
            Divider()
            HStack(spacing: 0) {
                accountList
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: Layout.userAccountsHeight)
            Divider()
            if !manager.failures.isEmpty { failures }
            buttons
                .gridProbe("buttons", area: "user-accounts")
                .padding(Space.margin)
        }
        .frame(width: Layout.userAccountsWidth)
        .gridArea("user-accounts", inset: 0)
        .noInitialFocus()
        .alert(deleteTitle, isPresented: $manager.confirmingDelete) {
            Button("Delete and Apply", role: .destructive, action: confirmDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(manager.deletedAccounts.map(\.text).joined(separator: ", ")
                + " can no longer log in, and their privileges are gone.")
        }
    }

    private var deleteTitle: String {
        let count = manager.deletedAccounts.count
        return count == 1 ? "Delete 1 Account?" : "Delete \(count) Accounts?"
    }

    // MARK: Accounts

    private var accountList: some View {
        VStack(spacing: 0) {
            List(selection: $manager.selection) {
                ForEach(manager.accounts) { account in
                    AccountRow(account: account, isCurrent: manager.isCurrent(account))
                        .tag(account.id)
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand { manager.removeSelected() }
            Divider()
            HStack(spacing: Space.xs) {
                Button { manager.addAccount() } label: {
                    Label("Add Account", systemImage: "plus").labelStyle(.iconOnly)
                }
                .help("Add an account, new_user@%, to fill in")
                .disabled(manager.isLoading || manager.loadError != nil || manager.isApplying)
                Button { manager.removeSelected() } label: {
                    Label("Remove Account", systemImage: "minus").labelStyle(.iconOnly)
                }
                .help("Remove the selected account; Apply deletes it from the server (Delete)")
                .disabled(!manager.canRemove)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(Space.sm)
        }
        .frame(width: Layout.userAccountsListWidth)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let error = manager.loadError {
            ContentUnavailableView {
                Label("Can’t Read Accounts", systemImage: StatusStyle.errorSymbol)
            } description: {
                Text(error.message + "\nThe account you connected with needs SELECT on mysql.user and mysql.db.")
                    .textSelection(.enabled)
            }
        } else if manager.isLoading && manager.accounts.isEmpty {
            ProgressView().controlSize(.small).accessibilityLabel("Loading accounts")
        } else if let account = manager.selectedAccount {
            VStack(spacing: 0) {
                Picker("Show", selection: $manager.tab) {
                    ForEach(UserManager.Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, Space.md)
                switch manager.tab {
                case .general: AccountGeneralTab(manager: manager, account: account)
                case .global: GlobalPrivilegesTab(manager: manager)
                case .schema: SchemaPrivilegesTab(manager: manager)
                case .resources: ResourcesTab(manager: manager, account: account)
                }
            }
            .disabled(manager.isApplying)
        } else {
            ContentUnavailableView("Select an Account", systemImage: "person.crop.circle",
                                   description: Text("Or add one with +."))
        }
    }

    // MARK: Apply

    private var failures: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(manager.failures) { failure in
                Label {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(failure.message)
                        Text(failure.statement)
                            .font(DataStyle.gridFont)
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                } icon: {
                    Image(systemName: StatusStyle.errorSymbol).foregroundStyle(StatusStyle.error)
                }
                .accessibilityLabel("Error: \(failure.message)")
            }
        }
        .padding([.horizontal, .top], Space.margin)
    }

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            if manager.isApplying {
                ProgressView().controlSize(.small)
                Text("Applying…").font(.callout).foregroundStyle(.secondary)
            } else if let problem = manager.problem {
                Label(problem, systemImage: StatusStyle.warningSymbol)
                    .font(.callout)
                    .foregroundStyle(StatusStyle.warning)
                    .accessibilityLabel("Error: \(problem)")
            } else if !manager.failures.isEmpty {
                Text("The server refused \(manager.failures.count == 1 ? "1 change" : "\(manager.failures.count) changes"). The list shows the accounts as they are now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
                .disabled(manager.isApplying)
            Button("Apply", action: apply)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!manager.canApply)
                .help(applyHelp)
        }
    }

    private var applyHelp: String {
        let count = manager.statements.count
        guard count > 0 else { return "No changes to apply" }
        return "Send \(count == 1 ? "1 statement" : "\(count) statements") to the server: "
            + manager.statements.prefix(3).joined(separator: "; ") + (count > 3 ? "; …" : "")
    }
}

/// One account in the list: user name over host; the account you logged in as is marked.
private struct AccountRow: View {
    let account: UserAccount
    let isCurrent: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 0) {
                Text(account.name.user.isEmpty ? "Anonymous" : account.name.user)
                    .italic(account.name.user.isEmpty)
                    .lineLimit(1)
                Text(account.name.host.isEmpty ? "Any host" : account.name.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: isCurrent ? "person.crop.circle.fill" : "person.crop.circle")
        }
        .help(isCurrent ? "You are connected as \(account.name.text)" : account.name.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.name.text + (isCurrent ? ", your account" : "") + (account.isNew ? ", new" : ""))
    }
}
