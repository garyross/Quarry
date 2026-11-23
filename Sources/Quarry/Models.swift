import Foundation
import Observation
import QuarryKit
import QuarryControllers
import SwiftData

/// A saved connection in the Connect page's sidebar. The password lives in
/// the Keychain under `uid`, never in this store.
@Model
final class SavedConnection {
    var uid: UUID = UUID()
    var name: String = ""
    /// `ConnectionDetails.Transport` raw value: "tcp", "socket", "ssh" or "sqlite".
    var transport: String = "tcp"
    var host: String = ""
    var port: String = ""
    var socket: String = ""
    var user: String = ""
    var database: String = ""
    /// SSH (S-047); the SSH password is in the Keychain.
    var sshHost: String = ""
    var sshPort: String = ""
    var sshUser: String = ""
    var sshKey: String = ""
    /// SSL (S-058): on or off, and the key, certificate and CA files.
    var useSSL: Bool = false
    var sslKey: String = ""
    var sslCertificate: String = ""
    var sslCA: String = ""
    /// S-068: a SQLite file's path, Open Read Only, and a bookmark that finds the file after a move.
    var file: String = ""
    var readOnly: Bool = false
    var fileBookmark: Data?
    var createdAt: Date = Date.now
    var lastUsedAt: Date?
    /// S-049: the group it is in (`ConnectionGroup.uid`), nil for none.
    var groupID: UUID?
    /// S-049: `ConnectionColor` index, -1 for none.
    var colorIndex: Int = -1
    /// S-049: its place in Manual order within its section.
    var order: Int = 0
    /// S-049: new windows open with this connection selected.
    var isDefault: Bool = false

    init(details: ConnectionDetails) {
        apply(details)
    }

    func apply(_ details: ConnectionDetails) {
        name = details.name.trimmingCharacters(in: .whitespaces)
        transport = details.transport.rawValue
        socket = details.socket.trimmingCharacters(in: .whitespaces)
        host = details.host.trimmingCharacters(in: .whitespaces)
        port = details.port.trimmingCharacters(in: .whitespaces)
        user = details.user.trimmingCharacters(in: .whitespaces)
        database = details.database.trimmingCharacters(in: .whitespaces)
        sshHost = details.sshHost.trimmingCharacters(in: .whitespaces)
        sshPort = details.sshPort.trimmingCharacters(in: .whitespaces)
        sshUser = details.sshUser.trimmingCharacters(in: .whitespaces)
        sshKey = details.sshKey.trimmingCharacters(in: .whitespaces)
        useSSL = details.useSSL
        sslKey = details.sslKey.trimmingCharacters(in: .whitespaces)
        sslCertificate = details.sslCertificate.trimmingCharacters(in: .whitespaces)
        sslCA = details.sslCA.trimmingCharacters(in: .whitespaces)
        let path = details.transport == .sqlite ? details.file.trimmingCharacters(in: .whitespaces) : ""
        if path != file || fileBookmark == nil {
            fileBookmark = details.fileURL.flatMap { try? $0.bookmarkData(options: .minimalBookmark) }
        }
        file = path
        readOnly = details.transport == .sqlite && details.readOnly
    }

    /// The file's path now: the bookmark follows a file moved or renamed in the Finder (S-068).
    var currentFile: String {
        guard let bookmark = fileBookmark else { return file }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return file }
        // A moved file answers by its new path from now on; /tmp and /private/tmp are one place.
        let stored = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        if url.resolvingSymlinksInPath().path != stored.resolvingSymlinksInPath().path || stale {
            file = (url.path as NSString).abbreviatingWithTildeInPath
            fileBookmark = try? url.bookmarkData(options: .minimalBookmark)
        }
        return file
    }

    /// The form's fields for this connection, without passwords.
    var fields: ConnectionDetails {
        ConnectionDetails(name: name, transport: kind, host: host, port: port, socket: socket, user: user,
                          database: database, sshHost: sshHost, sshPort: sshPort, sshUser: sshUser, sshKey: sshKey,
                          useSSL: useSSL, sslKey: sslKey, sslCertificate: sslCertificate, sslCA: sslCA,
                          file: kind == .sqlite ? currentFile : file, readOnly: readOnly)
    }

    /// The form's fields for this connection. The passwords come from the Keychain.
    var details: ConnectionDetails {
        var details = fields
        PasswordStore.fill(&details, from: uid)
        return details
    }

    var kind: ConnectionDetails.Transport { ConnectionDetails.Transport(rawValue: transport) ?? .tcp }

    var displayName: String { fields.displayName }

    /// The row's second line (`ConnectionDetails.summary`).
    var summary: String { fields.summary }

    var color: ConnectionColor? { ConnectionColor(index: colorIndex) }
}

/// App-wide state shared by every window and Settings.
@Observable
final class AppModel {
    let container: ModelContainer
    /// Settings reopens on the last tab. Test and snapshot runs leave it alone.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }

    /// Every favorite database, by name, then server. Observed, so the
    /// database menu, the Connect page and the menus update in every window.
    private(set) var favorites: [FavoriteDatabase] = []
    /// Every saved filter, by name (S-062). Observed, so every window's menus update.
    private(set) var savedFilters: [SavedFilter] = []
    /// Every query history entry, newest first (S-033). Observed, so every window's history updates.
    var queryHistory: [QueryHistoryEntry] = []
    /// Every saved query, by name (S-034). Observed, so menus and the Saved Queries window update.
    var savedQueries: [SavedQuery] = []
    /// Every MCP token, the Automatic one first (S-064). Observed, so Settings updates.
    var agentTokens: [AgentToken] = []
    /// Every request agents made in the last 30 days, newest first (S-065). Observed, so MCP Activity updates.
    var agentActivity: [ActivityRecord] = []
    @ObservationIgnored var lastActivityPrune = Date.distantPast

    /// S-049: how the Connect page orders connections and groups. Test and snapshot runs keep it in memory.
    var connectionOrder: ConnectionOrder = ConnectionOrder(rawValue: Store.isOverridden ? "" : UserDefaults.standard.string(forKey: "connections.order") ?? "") ?? .manual {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(connectionOrder.rawValue, forKey: "connections.order") } }
    }
    var connectionOrderReversed: Bool = Store.isOverridden ? false : UserDefaults.standard.bool(forKey: "connections.reversed") {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(connectionOrderReversed, forKey: "connections.reversed") } }
    }
    init(container: ModelContainer) {
        self.container = container
        reloadFavorites()
        reloadSavedFilters()
        reloadHistory()
        reloadSavedQueries()
        reloadAgentTokens()
        reloadAgentActivity()
    }

    var context: ModelContext { container.mainContext }

    func savedConnections() -> [SavedConnection] {
        let descriptor = FetchDescriptor<SavedConnection>(sortBy: [SortDescriptor(\.name), SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func savedConnection(_ uid: UUID?) -> SavedConnection? {
        guard let uid else { return nil }
        return savedConnections().first { $0.uid == uid }
    }

    /// Saves the form as a new connection, or updates `existing`. Returns its uid.
    @discardableResult
    func save(_ details: ConnectionDetails, over existing: UUID?) -> UUID {
        let saved: SavedConnection
        if let found = savedConnection(existing) {
            found.apply(details)
            saved = found
        } else {
            saved = SavedConnection(details: details)
            saved.order = (savedConnections().map(\.order).max() ?? -1) + 1
            context.insert(saved)
        }
        PasswordStore.store(details, for: saved.uid)
        try? context.save()
        return saved.uid
    }

    func delete(_ uid: UUID) {
        guard let saved = savedConnection(uid) else { return }
        PasswordStore.remove(uid)
        context.delete(saved)
        try? context.save()
    }

    /// The SSH key a passphrase was remembered for (S-047), on a saved connection or favorite.
    func rememberSSHKey(_ key: String, for uid: UUID) {
        if let saved = savedConnection(uid) {
            saved.sshKey = key
        } else if let favorite = favorite(uid) {
            favorite.sshKey = key
        }
        try? context.save()
    }

    func markUsed(_ uid: UUID?) {
        savedConnection(uid)?.lastUsedAt = .now
        try? context.save()
    }

    // MARK: Favorite databases (S-060)

    private func reloadFavorites() {
        let descriptor = FetchDescriptor<FavoriteDatabase>(sortBy: [SortDescriptor(\.database), SortDescriptor(\.createdAt)])
        favorites = (try? context.fetch(descriptor)) ?? []
    }

    /// The names starred on the server and user that `details` reach.
    func favoriteNames(on details: ConnectionDetails?) -> Set<String> {
        guard let details else { return [] }
        let key = FavoriteDatabase.serverKey(for: details)
        return Set(favorites.filter { $0.serverKey == key }.map(\.database))
    }

    func favorite(_ uid: UUID?) -> FavoriteDatabase? {
        favorites.first { $0.uid == uid }
    }

    /// Stars `database`, or unstars it when it is already a favorite.
    /// The connection's password is copied, so the favorite opens on its own.
    func toggleFavorite(_ database: String, on details: ConnectionDetails) {
        let key = FavoriteDatabase.serverKey(for: details)
        if let found = favorites.first(where: { $0.serverKey == key && $0.database == database }) {
            removeFavorite(found.uid)
            return
        }
        let favorite = FavoriteDatabase(database: database, details: details)
        context.insert(favorite)
        PasswordStore.store(details, for: favorite.uid)
        try? context.save()
        reloadFavorites()
    }

    func removeFavorite(_ uid: UUID) {
        guard let favorite = favorite(uid) else { return }
        PasswordStore.remove(uid)
        context.delete(favorite)
        try? context.save()
        reloadFavorites()
    }

    /// Rename Database (S-019): favorites and saved filters follow the database.
    func renameDatabase(_ old: String, to new: String, on details: ConnectionDetails) {
        let key = FavoriteDatabase.serverKey(for: details)
        for favorite in favorites where favorite.serverKey == key && favorite.database == old { favorite.database = new }
        for filter in savedFilters where filter.serverKey == key && filter.database == old { filter.database = new }
        try? context.save()
        reloadFavorites()
        reloadSavedFilters()
    }

    /// Delete Database (S-019): its favorites (and their passwords) and saved filters go.
    func forgetDatabase(_ name: String, on details: ConnectionDetails) {
        let key = FavoriteDatabase.serverKey(for: details)
        for favorite in favorites where favorite.serverKey == key && favorite.database == name {
            PasswordStore.remove(favorite.uid)
            context.delete(favorite)
        }
        for filter in savedFilters where filter.serverKey == key && filter.database == name { context.delete(filter) }
        try? context.save()
        reloadFavorites()
        reloadSavedFilters()
    }

    /// Rename Table (S-022): the table's saved filters follow it.
    func renameTable(_ old: String, to new: String, in database: String, on details: ConnectionDetails) {
        let key = FavoriteDatabase.serverKey(for: details)
        for filter in savedFilters where filter.serverKey == key && filter.database == database && filter.table == old {
            filter.table = new
        }
        try? context.save()
        reloadSavedFilters()
    }

    /// Delete Table (S-022): the table's saved filters go.
    func forgetTable(_ name: String, in database: String, on details: ConnectionDetails) {
        let key = FavoriteDatabase.serverKey(for: details)
        for filter in savedFilters where filter.serverKey == key && filter.database == database && filter.table == name {
            context.delete(filter)
        }
        try? context.save()
        reloadSavedFilters()
    }

    func markFavoriteUsed(_ uid: UUID?) {
        favorite(uid)?.lastUsedAt = .now
        try? context.save()
    }

    // MARK: Saved filters (S-062)

    private func reloadSavedFilters() {
        let descriptor = FetchDescriptor<SavedFilter>(sortBy: [SortDescriptor(\.name), SortDescriptor(\.createdAt)])
        savedFilters = (try? context.fetch(descriptor)) ?? []
    }

    /// The filters saved on one table.
    func savedFilters(on place: SavedFilter.Place?) -> [SavedFilter] {
        guard let place else { return [] }
        return savedFilters.filter { $0.place == place }
    }

    /// Saves `tree` as `name` on the table; a filter with that name there is replaced.
    @discardableResult
    func saveFilter(_ tree: FilterTree, named name: String, on place: SavedFilter.Place) -> SavedFilter {
        let name = name.trimmingCharacters(in: .whitespaces)
        if let found = savedFilters(on: place).first(where: { $0.name == name }) {
            found.tree = tree.encoded()
            found.updatedAt = .now
            try? context.save()
            reloadSavedFilters()
            return found
        }
        let saved = SavedFilter(name: name, place: place, tree: tree)
        context.insert(saved)
        try? context.save()
        reloadSavedFilters()
        return saved
    }

    func deleteSavedFilter(_ uid: UUID) {
        guard let found = savedFilters.first(where: { $0.uid == uid }) else { return }
        context.delete(found)
        try? context.save()
        reloadSavedFilters()
    }

    /// Rows per page in Content (Settings > General).
    static var pageSize: Int {
        let stored = UserDefaults.standard.integer(forKey: "content.pageSize")
        return stored > 0 ? stored : LoadState.defaultPageSize
    }

    /// Settings > Network (S-050): whether to ping idle connections, and how often.
    static let keepAliveKey = "network.keepAlive"
    static let keepAliveIntervalKey = "network.keepAliveInterval"
    static let defaultKeepAliveInterval = 60

    /// Seconds between keep-alive pings, or nil when they are off.
    static var keepAliveInterval: Int? {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: keepAliveKey) != nil, !defaults.bool(forKey: keepAliveKey) { return nil }
        let stored = defaults.integer(forKey: keepAliveIntervalKey)
        return stored > 0 ? stored : defaultKeepAliveInterval
    }
}
