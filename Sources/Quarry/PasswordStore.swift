import Foundation
import QuarryKit
import Security

/// Connection passwords in the login Keychain, one generic password per
/// saved connection. Test and snapshot runs use their own service name, so
/// they never read or overwrite real passwords.
nonisolated enum PasswordStore {
    static var service: String {
        Store.isOverridden ? "app.quarry.mac.test" : "app.quarry.mac"
    }

    /// The MySQL password, or with `ssh` the SSH password or key passphrase (S-047).
    static func password(for uid: UUID, ssh: Bool = false) -> String? {
        var query = baseQuery(uid, ssh: ssh)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Both passwords of one connection, read from and written to the Keychain.
    static func fill(_ details: inout ConnectionDetails, from uid: UUID) {
        details.password = password(for: uid) ?? ""
        details.sshPassword = password(for: uid, ssh: true) ?? ""
    }

    static func store(_ details: ConnectionDetails, for uid: UUID) {
        setPassword(details.password, for: uid)
        setPassword(details.transport == .ssh ? details.sshPassword : "", for: uid, ssh: true)
    }

    static func remove(_ uid: UUID) {
        setPassword("", for: uid)
        setPassword("", for: uid, ssh: true)
    }

    /// An empty password removes the item.
    static func setPassword(_ password: String, for uid: UUID, ssh: Bool = false) {
        let query = baseQuery(uid, ssh: ssh)
        guard !password.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = ssh ? "Quarry SSH password" : "Quarry connection password"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func baseQuery(_ uid: UUID, ssh: Bool) -> [String: Any] {
        baseQuery(account: uid.uuidString + (ssh ? ".ssh" : ""))
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    // MARK: Other secrets

    /// A secret Quarry keeps for itself, such as the MCP server's token (S-063).
    static func secret(_ account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setSecret(_ value: String, _ account: String, label: String) {
        let query = baseQuery(account: account)
        let data = Data(value.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func removeSecret(_ account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
