import QuarryKit
import QuarryControllers
import SwiftUI

/// The User Accounts sheet's tabs (S-051).

/// General: the account's name, host and a new password.
struct AccountGeneralTab: View {
    let manager: UserManager
    let account: UserAccount

    var body: some View {
        Form {
            Section {
                TextField("User Name", text: text(\.name.user), prompt: Text(account.isNew ? "Required" : "Anonymous"))
                    .help("The name people log in with")
                TextField("Host", text: text(\.name.host), prompt: Text("Any host"))
                    .help("Where the account may connect from: % for anywhere, localhost for this server’s own computer, or a pattern such as 10.0.0.%")
                SecureField("Password", text: password, prompt: Text(account.isNew ? "None" : "Unchanged"))
                    .help(account.isNew ? "Empty: the account logs in without a password"
                                        : "Empty keeps the current password")
            } footer: {
                if manager.isCurrent(account) {
                    Text("You are connected as this account. A new name or password applies to your next connection.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func text(_ path: WritableKeyPath<UserAccount, String>) -> Binding<String> {
        Binding(get: { manager.selectedAccount?[keyPath: path] ?? "" },
                set: { value in manager.edit { $0[keyPath: path] = value } })
    }

    /// Empty means "keep it" for an existing account and "none" for a new one.
    private var password: Binding<String> {
        Binding(get: { manager.selectedAccount?.password ?? "" },
                set: { value in manager.edit { $0.password = value.isEmpty && !$0.isNew ? nil : value } })
    }
}

/// Global Privileges: what the account may do on every database, in groups.
struct GlobalPrivilegesTab: View {
    let manager: UserManager

    var body: some View {
        Form {
            ForEach(Privilege.Group.allCases) { group in
                let privileges = group.privileges.filter(manager.catalog.global.contains)
                if !privileges.isEmpty {
                    Section {
                        PrivilegeGrid(privileges: privileges, columns: 3,
                                      isOn: { manager.isGranted($0) }, set: { manager.setGranted($0, $1) })
                    } header: {
                        GroupHeader(title: group.title, allOn: privileges.allSatisfy(manager.isGranted)) {
                            manager.setGranted(group, $0)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Schema Privileges: a database list and the selected database's privileges.
struct SchemaPrivilegesTab: View {
    @Bindable var manager: UserManager

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $manager.schema) {
                ForEach(manager.schemaNames, id: \.self) { name in
                    let count = manager.schemaPrivileges(name).count
                    HStack {
                        Label(name, systemImage: "cylinder")
                            .lineLimit(1)
                        Spacer()
                        if count > 0 {
                            Text("\(count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(name)
                    .help(count == 0 ? "No privileges on \(name)" : "\(count) privileges on \(name)")
                    .accessibilityLabel(count == 0 ? name : "\(name), \(count) privileges")
                }
            }
            .listStyle(.sidebar)
            .frame(width: Layout.schemaListWidth)
            Divider()
            if let schema = manager.schema {
                Form {
                    ForEach([Privilege.Group.data, .viewsAndRoutines, .administration]) { group in
                        let privileges = group.privileges.filter(manager.catalog.schema.contains)
                        if !privileges.isEmpty {
                            Section {
                                PrivilegeGrid(privileges: privileges, columns: 2,
                                              isOn: { manager.isGranted($0, on: schema) },
                                              set: { manager.setGranted([$0], $1, on: schema) })
                            } header: {
                                GroupHeader(title: group.title,
                                            allOn: privileges.allSatisfy { manager.isGranted($0, on: schema) }) {
                                    manager.setGranted(privileges, $0, on: schema)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView("Select a Database", systemImage: "cylinder",
                                       description: Text("Privileges given here apply to that database only."))
            }
        }
        .padding(.top, Space.md)
    }
}

/// Resources: hourly limits and simultaneous connections.
struct ResourcesTab: View {
    let manager: UserManager
    let account: UserAccount

    var body: some View {
        Form {
            Section {
                field("Max Queries per Hour", \.maxQueries, "Statements the account may run in an hour")
                field("Max Updates per Hour", \.maxUpdates, "Statements that change data the account may run in an hour")
                field("Max Connections per Hour", \.maxConnections, "Times the account may connect in an hour")
                field("Max Simultaneous Connections", \.maxUserConnections, "Connections the account may hold open at once")
            } footer: {
                Text("0 means no limit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func field(_ title: String, _ path: WritableKeyPath<ResourceLimits, Int>, _ help: String) -> some View {
        TextField(title, value: Binding(get: { manager.selectedAccount?.limits[keyPath: path] ?? 0 },
                                        set: { value in manager.edit { $0.limits[keyPath: path] = max(0, value) } }),
                  format: .number)
            .multilineTextAlignment(.trailing)
            .help(help)
    }
}

/// Checkboxes in columns, each with its privilege's meaning as a tooltip.
private struct PrivilegeGrid: View {
    let privileges: [Privilege]
    let columns: Int
    let isOn: (Privilege) -> Bool
    let set: (Privilege, Bool) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns),
                  alignment: .leading, spacing: Space.sm) {
            ForEach(privileges) { privilege in
                Toggle(privilege.title, isOn: Binding(get: { isOn(privilege) }, set: { set(privilege, $0) }))
                    .toggleStyle(.checkbox)
                    .help(privilege.help + " (" + privilege.sql + ")")
            }
        }
    }
}

/// A group's title with Select All or Select None.
private struct GroupHeader: View {
    let title: String
    let allOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(allOn ? "Select None" : "Select All") { set(!allOn) }
                .buttonStyle(.link)
                .font(.callout)
                .help(allOn ? "Clear every privilege in \(title)" : "Give every privilege in \(title)")
        }
    }
}
