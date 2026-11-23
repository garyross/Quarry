import Foundation
import QuarryKit
import SwiftData

/// Sample data for snapshots: APP_SEED=1 with APP_STORE in /tmp fills an empty
/// store with three saved connections. "Local" and "Local Socket" point at the private test
/// server (tools/testdb.sh), with its password in the test Keychain service.
@MainActor
enum SeedData {
    static let local = ConnectionDetails(name: "Local", host: "127.0.0.1", port: "3399", user: "quarry",
                                         password: "quarry", database: "quarry_demo")
    /// The test server's socket (tools/testdb.sh).
    static let testSocket = NSHomeDirectory() + "/Library/Developer/Quarry/test-db/mysqld.sock"
    static let localSocket = ConnectionDetails(name: "Local Socket", transport: .socket, socket: testSocket,
                                               user: "quarry", password: "quarry", database: "quarry_demo")
    static let staging = ConnectionDetails(name: "Staging", transport: .ssh, host: "127.0.0.1", port: "", user: "deploy",
                                           password: "", database: "", sshHost: "staging.example.internal",
                                           sshUser: "deploy", sshKey: "~/.ssh/id_ed25519")

    static func insertIfRequested(into model: AppModel) {
        guard ProcessInfo.processInfo.environment["APP_SEED"] == "1" else { return }
        guard Store.isOverridden else {
            print("APP_SEED ignored: APP_STORE must be a file in /tmp")
            return
        }
        guard model.savedConnections().isEmpty else { return }
        let localID = model.save(local, over: nil)
        model.save(localSocket, over: nil)
        let stagingID = model.save(staging, over: nil)
        // S-049: Staging in a group "Work", Local tagged green and the default.
        model.setColor(.green, of: localID)
        model.toggleDefault(localID)
        let work = model.newGroup(moving: stagingID)
        model.renameGroup(work.uid, to: "Work")
        model.setColor(.orange, of: stagingID)
        // Favorite databases (S-060) on the test server, not tied to a connection.
        model.toggleFavorite("quarry_demo", on: local)
        model.toggleFavorite("quarry_legacy", on: localSocket)
    }
}
