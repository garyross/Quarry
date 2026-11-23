import Foundation

/// A privilege the User Accounts sheet can grant (S-051), on the whole server
/// (Global Privileges) or on one database (Schema Privileges). Each one is a
/// `*_priv` column in mysql.user and, when it applies to a database, in mysql.db.
/// Newer privileges a server has only in its own tables (MariaDB's BINLOG ADMIN,
/// MySQL's dynamic ones) are not listed, so Quarry never grants or revokes them.
public enum Privilege: String, CaseIterable, Sendable, Hashable, Identifiable {
    case select, insert, update, delete, create, drop, alter, index, references, trigger
    case deleteHistory, createTemporaryTables, lockTables
    case createView, showView, createRoutine, alterRoutine, execute, event
    case reload, shutdown, process, file, superPrivilege, showDatabases, createUser, createTablespace, grantOption
    case replicationClient, replicationSlave

    public var id: String { rawValue }

    public enum Group: String, CaseIterable, Sendable, Identifiable {
        case data, viewsAndRoutines, administration, replication

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .data: "Data and Tables"
            case .viewsAndRoutines: "Views and Routines"
            case .administration: "Administration"
            case .replication: "Replication"
            }
        }

        public var privileges: [Privilege] { Privilege.allCases.filter { $0.group == self } }
    }

    public var group: Group {
        switch self {
        case .select, .insert, .update, .delete, .create, .drop, .alter, .index, .references, .trigger,
             .deleteHistory, .createTemporaryTables, .lockTables: .data
        case .createView, .showView, .createRoutine, .alterRoutine, .execute, .event: .viewsAndRoutines
        case .reload, .shutdown, .process, .file, .superPrivilege, .showDatabases, .createUser, .createTablespace,
             .grantOption: .administration
        case .replicationClient, .replicationSlave: .replication
        }
    }

    /// The name in GRANT and REVOKE.
    public var sql: String {
        switch self {
        case .deleteHistory: "DELETE HISTORY"
        case .createTemporaryTables: "CREATE TEMPORARY TABLES"
        case .lockTables: "LOCK TABLES"
        case .createView: "CREATE VIEW"
        case .showView: "SHOW VIEW"
        case .createRoutine: "CREATE ROUTINE"
        case .alterRoutine: "ALTER ROUTINE"
        case .superPrivilege: "SUPER"
        case .showDatabases: "SHOW DATABASES"
        case .createUser: "CREATE USER"
        case .createTablespace: "CREATE TABLESPACE"
        case .grantOption: "GRANT OPTION"
        case .replicationClient: "REPLICATION CLIENT"
        case .replicationSlave: "REPLICATION SLAVE"
        default: rawValue.uppercased()
        }
    }

    /// The column in mysql.user and mysql.db.
    public var column: String {
        switch self {
        case .deleteHistory: "Delete_history_priv"
        case .createTemporaryTables: "Create_tmp_table_priv"
        case .lockTables: "Lock_tables_priv"
        case .createView: "Create_view_priv"
        case .showView: "Show_view_priv"
        case .createRoutine: "Create_routine_priv"
        case .alterRoutine: "Alter_routine_priv"
        case .superPrivilege: "Super_priv"
        case .showDatabases: "Show_db_priv"
        case .createUser: "Create_user_priv"
        case .createTablespace: "Create_tablespace_priv"
        case .grantOption: "Grant_priv"
        case .replicationClient: "Repl_client_priv"
        case .replicationSlave: "Repl_slave_priv"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst() + "_priv"
        }
    }

    /// The checkbox's title.
    public var title: String {
        switch self {
        case .superPrivilege: "Super"
        case .replicationClient: "Replication Client"
        case .replicationSlave: "Replication Slave"
        default: sql.lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    /// The checkbox's tooltip: what the privilege lets the account do.
    public var help: String {
        switch self {
        case .select: "Read rows"
        case .insert: "Add rows"
        case .update: "Change rows"
        case .delete: "Delete rows"
        case .create: "Create databases and tables"
        case .drop: "Delete databases, tables and views"
        case .alter: "Change tables"
        case .index: "Add and delete indexes"
        case .references: "Create foreign keys"
        case .trigger: "Create and delete triggers"
        case .deleteHistory: "Delete old rows from system-versioned tables"
        case .createTemporaryTables: "Create temporary tables"
        case .lockTables: "Use LOCK TABLES on tables it can read"
        case .createView: "Create views"
        case .showView: "See views’ create statements"
        case .createRoutine: "Create procedures and functions"
        case .alterRoutine: "Change and delete procedures and functions"
        case .execute: "Call procedures and functions"
        case .event: "Create, change and delete scheduled events"
        case .reload: "Flush tables, logs and privileges"
        case .shutdown: "Shut the server down"
        case .process: "See every connection’s queries"
        case .file: "Read and write files on the server’s computer"
        case .superPrivilege: "Kill other connections, set global variables and more"
        case .showDatabases: "See every database’s name"
        case .createUser: "Create, rename and delete accounts"
        case .createTablespace: "Create and delete tablespaces"
        case .grantOption: "Give its own privileges to other accounts"
        case .replicationClient: "See where the server’s replication stands"
        case .replicationSlave: "Read the binary log, as a replica does"
        }
    }

    /// Privileges that apply to one database. The others exist only on the whole server.
    public var appliesToSchema: Bool {
        switch group {
        case .data, .viewsAndRoutines: true
        case .administration: self == .grantOption
        case .replication: false
        }
    }
}

/// `'user'@'host'`, as account statements name an account.
public struct AccountName: Hashable, Sendable, Comparable {
    public var user: String
    public var host: String

    public init(user: String, host: String) {
        self.user = user
        self.host = host
    }

    public var sql: String { SQLQuote.mysqlLiteral(user) + "@" + SQLQuote.mysqlLiteral(host) }

    /// "quarry@localhost"; the anonymous account is "Anonymous@localhost".
    public var text: String { (user.isEmpty ? "Anonymous" : user) + "@" + host }

    public static func < (a: AccountName, b: AccountName) -> Bool {
        let user = a.user.localizedStandardCompare(b.user)
        return user == .orderedSame ? a.host.localizedStandardCompare(b.host) == .orderedAscending : user == .orderedAscending
    }

    /// Reads `CURRENT_USER()`'s "user@host".
    public init?(currentUser: String) {
        guard let at = currentUser.lastIndex(of: "@") else { return nil }
        self.init(user: String(currentUser[..<at]), host: String(currentUser[currentUser.index(after: at)...]))
    }
}

/// Per-hour limits and simultaneous connections; 0 means no limit.
public struct ResourceLimits: Equatable, Sendable {
    public var maxQueries = 0
    public var maxUpdates = 0
    public var maxConnections = 0
    public var maxUserConnections = 0

    public init(maxQueries: Int = 0, maxUpdates: Int = 0, maxConnections: Int = 0, maxUserConnections: Int = 0) {
        self.maxQueries = maxQueries
        self.maxUpdates = maxUpdates
        self.maxConnections = maxConnections
        self.maxUserConnections = maxUserConnections
    }

    /// `MAX_QUERIES_PER_HOUR 100 …` for the limits that differ from `old`.
    func clauses(from old: ResourceLimits) -> [String] {
        var out: [String] = []
        if maxQueries != old.maxQueries { out.append("MAX_QUERIES_PER_HOUR \(max(0, maxQueries))") }
        if maxUpdates != old.maxUpdates { out.append("MAX_UPDATES_PER_HOUR \(max(0, maxUpdates))") }
        if maxConnections != old.maxConnections { out.append("MAX_CONNECTIONS_PER_HOUR \(max(0, maxConnections))") }
        if maxUserConnections != old.maxUserConnections { out.append("MAX_USER_CONNECTIONS \(max(0, maxUserConnections))") }
        return out
    }
}

/// One account, user@host, as the User Accounts sheet edits it (S-051).
public struct UserAccount: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: AccountName
    /// The name on the server; nil for an account added in the sheet.
    public let original: AccountName?
    /// A new password; nil keeps the current one.
    public var password: String?
    public var privileges: Set<Privilege>
    /// Database name (or pattern, such as `test\_%`) → its privileges.
    public var schemas: [String: Set<Privilege>]
    public var limits: ResourceLimits

    public init(id: UUID = UUID(), name: AccountName, original: AccountName?, password: String? = nil,
                privileges: Set<Privilege> = [], schemas: [String: Set<Privilege>] = [:], limits: ResourceLimits = .init()) {
        self.id = id
        self.name = name
        self.original = original
        self.password = password
        self.privileges = privileges
        self.schemas = schemas
        self.limits = limits
    }

    public var isNew: Bool { original == nil }

    /// Reads mysql.user and mysql.db (`SELECT *`). Roles and rows for
    /// accounts that are not listed (MariaDB's PUBLIC) are left out.
    public static func accounts(users: StatementResult, schemas: StatementResult) -> [UserAccount] {
        var accounts: [AccountName: UserAccount] = [:]
        for row in users.rows.indices {
            if users.string(row, "is_role") == "Y" { continue }
            guard let user = users.string(row, "User"), let host = users.string(row, "Host") else { continue }
            let name = AccountName(user: user, host: host)
            let number = { (column: String) in Int(users.string(row, column) ?? "") ?? 0 }
            accounts[name] = UserAccount(
                name: name, original: name,
                privileges: Set(Privilege.allCases.filter { users.string(row, $0.column) == "Y" }),
                limits: ResourceLimits(maxQueries: number("max_questions"), maxUpdates: number("max_updates"),
                                       maxConnections: number("max_connections"),
                                       maxUserConnections: number("max_user_connections")))
        }
        for row in schemas.rows.indices {
            guard let user = schemas.string(row, "User"), let host = schemas.string(row, "Host"),
                  let db = schemas.string(row, "Db") else { continue }
            let name = AccountName(user: user, host: host)
            guard accounts[name] != nil else { continue }
            let granted = Set(Privilege.allCases.filter { $0.appliesToSchema && schemas.string(row, $0.column) == "Y" })
            if !granted.isEmpty { accounts[name]?.schemas[db] = granted }
        }
        return accounts.values.sorted { $0.name < $1.name }
    }
}

/// Which privileges the server's tables hold, from the columns of mysql.user
/// and mysql.db: an older server has no Delete History, for example.
public struct PrivilegeCatalog: Equatable, Sendable {
    public var global: [Privilege]
    public var schema: [Privilege]

    public init(global: [Privilege], schema: [Privilege]) {
        self.global = global
        self.schema = schema
    }

    public init(users: StatementResult, schemas: StatementResult) {
        let userColumns = Set(users.columns.map { $0.name.lowercased() })
        let dbColumns = Set(schemas.columns.map { $0.name.lowercased() })
        global = Privilege.allCases.filter { userColumns.contains($0.column.lowercased()) }
        schema = Privilege.allCases.filter { $0.appliesToSchema && dbColumns.contains($0.column.lowercased()) }
    }

    public static let all = PrivilegeCatalog(global: Privilege.allCases, schema: Privilege.allCases.filter(\.appliesToSchema))
}

/// The statements that turn the server's accounts into the edited ones (S-051):
/// DROP USER, RENAME USER, CREATE USER, ALTER USER for passwords and limits,
/// and per account and scope at most one GRANT and one REVOKE.
public enum AccountChanges {
    public static func statements(from old: [UserAccount], to new: [UserAccount]) -> [String] {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(new.map(\.id))
        var drops: [String] = [], renames: [String] = [], creates: [String] = [], changes: [String] = []
        for account in old where !kept.contains(account.id) {
            drops.append("DROP USER " + (account.original ?? account.name).sql)
        }
        for account in new {
            let previous = before[account.id]
            let name = account.name.sql
            if let previous, let original = previous.original {
                if account.name != original {
                    renames.append("RENAME USER \(original.sql) TO \(name)")
                }
                if let password = account.password {
                    changes.append("ALTER USER \(name) IDENTIFIED BY \(SQLQuote.mysqlLiteral(password))")
                }
                let limits = account.limits.clauses(from: previous.limits)
                if !limits.isEmpty {
                    changes.append("ALTER USER \(name) WITH " + limits.joined(separator: " "))
                }
            } else {
                var create = "CREATE USER \(name)"
                if let password = account.password, !password.isEmpty {
                    create += " IDENTIFIED BY " + SQLQuote.mysqlLiteral(password)
                }
                let limits = account.limits.clauses(from: ResourceLimits())
                if !limits.isEmpty { create += " WITH " + limits.joined(separator: " ") }
                creates.append(create)
            }
            changes += grants(previous?.privileges ?? [], account.privileges, on: "*.*", account: name)
            let databases = Set((previous?.schemas.keys).map(Array.init) ?? []).union(account.schemas.keys)
            for db in databases.sorted() {
                changes += grants(previous?.schemas[db] ?? [], account.schemas[db] ?? [],
                                  on: SQLQuote.identifier(db) + ".*", account: name)
            }
        }
        return drops + renames + creates + changes
    }

    /// One REVOKE for what was taken away and one GRANT for what was added.
    static func grants(_ old: Set<Privilege>, _ new: Set<Privilege>, on scope: String, account: String) -> [String] {
        var out: [String] = []
        let removed = Privilege.allCases.filter { old.contains($0) && !new.contains($0) }
        if !removed.isEmpty {
            out.append("REVOKE \(removed.map(\.sql).joined(separator: ", ")) ON \(scope) FROM \(account)")
        }
        let added = Privilege.allCases.filter { new.contains($0) && !old.contains($0) }
        let plain = added.filter { $0 != .grantOption }
        if !added.isEmpty {
            let list = plain.isEmpty ? "USAGE" : plain.map(\.sql).joined(separator: ", ")
            out.append("GRANT \(list) ON \(scope) TO \(account)" + (added.contains(.grantOption) ? " WITH GRANT OPTION" : ""))
        }
        return out
    }
}
