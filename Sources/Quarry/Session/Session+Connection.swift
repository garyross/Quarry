import Foundation
import QuarryKit

/// A dropped connection (S-050): the Connection Lost sheet, Reconnect and Close Connection.
extension Session {
    /// The client reported itself gone; shows the sheet unless it was already replaced.
    func lost(_ lostClient: DatabaseClient) {
        guard lostClient === client, phase == .connected, !connectionLost else { return }
        reconnectProblem = nil
        connectionLost = true
    }

    /// Where the sheet says the connection went: "Local (127.0.0.1:3399)".
    var lostConnectionText: String {
        let config = connectedDetails?.driverConfiguration
        let place = config.map { $0.socketPath ?? "\($0.host):\($0.port)" } ?? ""
        let name = connectionName.isEmpty || connectionName == place ? place : "\(connectionName) (\(place))"
        return "Quarry lost the connection to \(name), or the server stopped responding."
    }

    /// Reconnect (Return): opens a new connection with the same details, then the
    /// same database, table and view. On an error the sheet stays with the reason.
    /// The task ends when the view has reloaded (self-test).
    @discardableResult
    func reconnect() -> Task<Void, Never>? {
        guard connectionLost, !isReconnecting, var details = connectedDetails else { return nil }
        isReconnecting = true
        reconnectProblem = nil
        // The database may be gone; USE it afterwards instead of failing the login.
        details.database = ""
        return Task {
            defer { isReconnecting = false }
            do {
                let fresh = try await DatabaseClient.connect(details)
                guard connectionLost, phase == .connected else {
                    await fresh.close()
                    return
                }
                let old = client
                attach(fresh)
                Task { await old?.close() }
                connectionLost = false
                await restore(on: fresh)
            } catch {
                reconnectProblem = DatabaseError.from(error, endpoint: details.driverConfiguration)
            }
        }
    }

    /// Close Connection: back to the Connect page with the form kept.
    func closeLostConnection() {
        disconnect()
    }

    /// Reloads the database list, the sidebar and the current view on the new connection.
    /// The other views drop what they loaded so they reload through it too.
    private func restore(on client: DatabaseClient) async {
        if view != .structure { structure.reset() }
        if view != .content { content.reset() }
        if view != .foreignKeys { foreignKeys.reset() }
        if view != .triggers { triggers.reset() }
        if view != .info { info.reset() }
        databaseInfo.reset()
        do {
            databases = try await client.databases()
        } catch {
            browseError = DatabaseError.from(error)
            return
        }
        guard let database else { return }
        guard databases.contains(database) else {
            self.database = nil
            return
        }
        do {
            try await client.use(database)
            try await loadObjects(client, database)
        } catch {
            browseError = DatabaseError.from(error)
            return
        }
        if selectedObject == nil { selectedObjectID = nil }
        reloadCurrentView(force: true)
        await currentLoad?.value
        loadDatabaseInfo(force: true)
    }
}
