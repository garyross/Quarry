import AppKit
import QuarryKit
import SwiftData

/// Self-test: Connecting, saved connections, favorite databases and a lost connection (S-001, S-002, S-060, S-050).
extension SelfTest {
    // MARK: S-001, S-002

    static func connecting(model: AppModel, session: Session) async {
        let clock = ContinuousClock()
        session.form = SeedData.local
        let start = clock.now
        session.connect(model: model)
        await session.waitForConnect()
        let elapsed = clock.now - start
        check("S-001 connects to the test server", session.phase == .connected, session.connectProblem?.message ?? "")
        check("S-001 connects within 2 s", elapsed < .seconds(2), "\(elapsed)")
        check("S-001 opens the form's database", session.database == "quarry_demo")
        session.disconnect()

        var wrong = SeedData.local
        wrong.password = "not-the-password"
        session.form = wrong
        session.connect(model: model)
        await session.waitForConnect()
        check("S-001 a wrong password shows the server's error",
              session.phase == .disconnected && session.connectProblem?.message.contains("Access denied") == true,
              session.connectProblem?.message ?? "no error")
        check("S-001 the form stays filled in", session.form.user == "quarry" && session.form.port == "3399")

        let uid = model.save(SeedData.local, over: nil)
        check("S-002 the password goes to the Keychain", PasswordStore.password(for: uid) == "quarry")
        let reopened = try? ModelContainer(for: Store.schema, configurations: ModelConfiguration(url: Store.url))
        let fresh = reopened.flatMap { try? ModelContext($0).fetch(FetchDescriptor<SavedConnection>()) }?.first { $0.uid == uid }
        check("S-002 a saved connection survives a store reload",
              fresh?.host == "127.0.0.1" && fresh?.port == "3399" && fresh?.user == "quarry" && fresh?.database == "quarry_demo")
        session.show(saved: model.savedConnection(uid))
        check("S-002 choosing it fills the form with the Keychain password", session.form == SeedData.local)
        session.connect(model: model)
        await session.waitForConnect()
        check("S-002 a saved connection connects", session.phase == .connected, session.connectProblem?.message ?? "")
        check("S-002 connecting records when it was used", model.savedConnection(uid)?.lastUsedAt != nil)
        session.disconnect()

        let socketUID = model.save(SeedData.localSocket, over: nil)
        session.show(saved: model.savedConnection(socketUID))
        check("S-048 a saved socket connection keeps its path", session.form == SeedData.localSocket)
        session.connect(model: model)
        await session.waitForConnect()
        check("S-048 connects through the socket", session.phase == .connected && session.database == "quarry_demo",
              session.connectProblem?.message ?? "")
        session.disconnect()
        var missing = SeedData.localSocket
        missing.socket = "/tmp/quarry-no-such.sock"
        session.form = missing
        session.connect(model: model)
        await session.waitForConnect()
        check("S-048 a missing socket says so", session.connectProblem?.message == "There is no socket at /tmp/quarry-no-such.sock.",
              session.connectProblem?.message ?? "no error")
        session.show(saved: model.savedConnection(uid))
        session.connect(model: model)
        await session.waitForConnect()
    }

    // MARK: S-060

    static func favorites(model: AppModel, session: Session) async {
        // The self-test connected from the form, with no saved connection.
        session.database = "quarry_demo"
        await session.currentLoad?.value
        let before = model.favorites.count
        session.toggleFavoriteDatabase()
        check("S-060 ⌘D stars the database", session.isFavoriteDatabase && model.favorites.count == before + 1
              && session.menuSnapshot.isFavoriteDatabase)
        check("S-060 it is listed first in the database menu", session.favoriteDatabases == ["quarry_demo"],
              "\(session.favoriteDatabases)")
        guard let favorite = model.favorites.first(where: { $0.database == "quarry_demo" }) else { return }
        var sameServer = SeedData.local
        sameServer.name = "Another Name"
        sameServer.host = " 127.0.0.1 "
        check("S-060 any connection to the same server and user sees it",
              model.favoriteNames(on: sameServer) == ["quarry_demo"])
        var otherUser = SeedData.local
        otherUser.user = "root"
        check("S-060 another user does not", model.favoriteNames(on: otherUser).isEmpty)

        session.disconnect()
        session.show(favorite: favorite)
        session.connect(model: model)
        await session.waitForConnect()
        await session.currentLoad?.value
        check("S-060 a favorite opens its database on its own", session.phase == .connected && session.database == "quarry_demo",
              session.connectProblem?.message ?? "database \(session.database ?? "none")")

        session.toggleFavoriteDatabase()
        check("S-060 ⌘D again removes it, with its password",
              !session.isFavoriteDatabase && model.favorite(favorite.uid) == nil && PasswordStore.password(for: favorite.uid) == nil)
        session.selectedFavorite = nil
    }

    // MARK: S-050

    static func connectionLoss(session: Session) async {
        guard let killer = try? await DatabaseClient.connect(SeedData.local) else {
            check("S-050 a second connection to kill the first", false)
            return
        }
        func kill() async {
            if let id = session.client?.connectionID { _ = try? await killer.run("KILL \(id)") }
        }
        session.database = "quarry_demo"
        await session.currentLoad?.value
        let customers = DBObject(name: "customers", kind: .table).id
        session.selectedObjectID = customers
        session.view = .content
        await session.currentLoad?.value
        session.query.text = "SELECT 'kept' AS text;"
        let before = session.client?.connectionID

        await kill()
        session.refresh()
        await session.currentLoad?.value
        await until { session.connectionLost }
        check("S-050 a connection killed on the server brings up Connection Lost", session.connectionLost)
        check("S-050 the sheet names the server", session.lostConnectionText.contains("127.0.0.1:3399"), session.lostConnectionText)

        // Pings every 0.7 s from the new connection on, to outlast a 2 s wait_timeout below.
        session.keepAliveOverride = .milliseconds(700)
        await session.reconnect()?.value
        check("S-050 Reconnect closes the sheet on a new connection",
              !session.connectionLost && session.client?.connectionID != before && session.client?.isClosed == false,
              session.reconnectProblem?.message ?? "")
        check("S-050 Reconnect restores the database, table and view",
              session.database == "quarry_demo" && session.selectedObjectID == customers && session.view == .content
              && !session.content.grid.rows.isEmpty && session.content.load.error == nil,
              session.content.load.error?.message ?? "")
        check("S-050 the Query text stays", session.query.text == "SELECT 'kept' AS text;")
        let current = try? await session.client?.run("SELECT DATABASE()").rows.first?.first?.plainText
        check("S-050 the new connection USEs the database", current == "quarry_demo", "\(String(describing: current))")

        // Keep-alive: with wait_timeout at 2 s, the pinged window survives 3.5 s idle; a bare connection does not.
        _ = try? await session.client?.run("SET SESSION wait_timeout = 2")
        let bare = try? await DatabaseClient.connect(SeedData.local)
        _ = try? await bare?.run("SET SESSION wait_timeout = 2")
        try? await Task.sleep(for: .milliseconds(3500))
        let pinged = try? await session.client?.run("SELECT 1")
        check("S-050 keep-alive pings stop an idle timeout", pinged != nil && !session.connectionLost)
        var bareError: DatabaseError?
        do { _ = try await bare?.run("SELECT 1") } catch { bareError = error as? DatabaseError }
        let bareLost = await bare?.wasLost ?? false
        check("S-050 without pings the server drops the idle connection, and it is reported lost",
              bareError != nil && bareLost, bareError?.message ?? "no error")
        await bare?.close()
        session.keepAliveOverride = nil

        // Close Connection: back to the Connect page with the form kept.
        await kill()
        session.refresh()
        await session.currentLoad?.value
        await until { session.connectionLost }
        session.closeLostConnection()
        check("S-050 Close Connection returns to the Connect page with the form",
              session.phase == .disconnected && !session.connectionLost && session.form.port == "3399")
        await killer.close()
    }
}
