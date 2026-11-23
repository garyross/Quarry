import AppKit
import Foundation
import Observation
import QuarryKit

/// The Server Processes window (S-053). It has its own connection, opened
/// from the window's, so refreshing and killing never wait on browsing and a
/// long query in the window it came from does not hold it up.
@Observable
final class ProcessList: Identifiable {
    /// Lists by window value; the window looks its list up here.
    static var open: [UUID: ProcessList] = [:]

    enum Key {
        static let full = "processesFull"
        static let autoRefresh = "processesAutoRefresh"
        static let interval = "processesInterval"
    }

    static let intervals = [2, 5, 10, 30, 60]

    let id = UUID()
    let server: String
    /// The connection of the window that opened it, marked in the list.
    let windowConnectionID: Int64?
    @ObservationIgnored private let source: DatabaseClient
    @ObservationIgnored private var client: DatabaseClient?
    @ObservationIgnored private var timer: Task<Void, Never>?

    private(set) var processes: [ServerProcess] = []
    private(set) var isLoading = false
    private(set) var error: DatabaseError?
    private(set) var isClosed = false
    private(set) var refreshedAt: Date?
    var search = ""
    var selection: Set<ServerProcess.ID> = []
    /// Kill Query… or Kill Connection… waiting on its alert.
    var pendingKill: (id: Int64, connection: Bool)?
    var killError: DatabaseError?

    var full: Bool {
        didSet { UserDefaults.standard.set(full, forKey: Key.full); Task { await refresh() } }
    }
    var autoRefresh: Bool {
        didSet { UserDefaults.standard.set(autoRefresh, forKey: Key.autoRefresh); restartTimer() }
    }
    var interval: Int {
        didSet { UserDefaults.standard.set(interval, forKey: Key.interval); restartTimer() }
    }

    init(server: String, source: DatabaseClient) {
        self.server = server
        self.source = source
        windowConnectionID = source.connectionID.map(Int64.init)
        let defaults = UserDefaults.standard
        full = defaults.bool(forKey: Key.full)
        autoRefresh = defaults.object(forKey: Key.autoRefresh) as? Bool ?? true
        let saved = defaults.integer(forKey: Key.interval)
        interval = saved > 0 ? saved : 5
    }

    /// The list's own connection ID; its SHOW PROCESSLIST is always in the list.
    var ownConnectionID: Int64? { client?.connectionID.map(Int64.init) }

    /// Opens the connection, reads the list and starts the timer.
    func start() async {
        guard client == nil, !isClosed else { return }
        isLoading = true
        do {
            client = try await source.secondConnection()
        } catch {
            self.error = DatabaseError.from(error)
            isLoading = false
            return
        }
        await refresh()
        restartTimer()
    }

    /// Refresh: SHOW [FULL] PROCESSLIST. Selected rows that are gone drop out of the selection.
    func refresh() async {
        guard let client, !isClosed else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            processes = try await client.processes(full: full)
            error = nil
            refreshedAt = .now
            selection.formIntersection(processes.map(\.id))
        } catch {
            self.error = DatabaseError.from(error)
        }
    }

    private func restartTimer() {
        timer?.cancel()
        timer = nil
        guard autoRefresh, client != nil, !isClosed else { return }
        let seconds = interval
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    /// The window closed, or its connection window disconnected.
    func stop() {
        guard !isClosed else { return }
        isClosed = true
        timer?.cancel()
        timer = nil
        let old = client
        client = nil
        Task { await old?.close() }
        Self.open[id] = nil
    }

    // MARK: Showing

    var shown: [ServerProcess] { ServerProcess.filter(processes, search) }

    var countText: String {
        let total = processes.count
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else {
            return total == 1 ? "1 process" : "\(total) processes"
        }
        return "\(shown.count) of \(total)"
    }

    func selected(_ ids: Set<ServerProcess.ID>? = nil) -> [ServerProcess] {
        let ids = ids ?? selection
        return shown.filter { ids.contains($0.id) }
    }

    @discardableResult
    func copy(_ ids: Set<ServerProcess.ID>? = nil) -> Bool {
        let rows = selected(ids)
        guard !rows.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ServerProcess.text(rows), forType: .string)
        return true
    }

    func save(to url: URL) throws {
        try ServerProcess.text(shown).write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Kill

    /// The one process Kill acts on: the clicked row, else the only selected row.
    func target(_ ids: Set<ServerProcess.ID>? = nil) -> ServerProcess? {
        let rows = selected(ids)
        return rows.count == 1 ? rows[0] : nil
    }

    func canKill(connection: Bool, _ ids: Set<ServerProcess.ID>? = nil) -> Bool {
        guard client != nil, let process = target(ids) else { return false }
        return connection || process.isRunning
    }

    /// Kill Query… or Kill Connection…: asks first.
    func requestKill(connection: Bool, _ ids: Set<ServerProcess.ID>? = nil) {
        guard canKill(connection: connection, ids), let process = target(ids) else { return }
        pendingKill = (process.id, connection)
    }

    /// Kill in the alert; then the list refreshes.
    @discardableResult
    func confirmKill() -> Task<Void, Never>? {
        guard let client, let kill = pendingKill else { return nil }
        pendingKill = nil
        return Task {
            do {
                try await client.kill(kill.id, connection: kill.connection)
            } catch {
                killError = DatabaseError.from(error)
            }
            await refresh()
        }
    }

    var killTitle: String {
        guard let kill = pendingKill else { return "" }
        return kill.connection ? "Kill Connection \(kill.id)?" : "Kill Query on Connection \(kill.id)?"
    }

    var killMessage: String {
        guard let kill = pendingKill else { return "" }
        let mine = kill.id == windowConnectionID ? " It is the connection of the window you opened this from." : ""
        return (kill.connection
            ? "The connection closes, and a transaction it has open is rolled back."
            : "Its statement stops with an error; the connection stays open. A statement that changes data is rolled back.")
            + mine
    }
}
