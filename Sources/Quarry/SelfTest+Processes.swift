import AppKit
import QuarryKit

/// Self-test: Server Processes (S-053).
extension SelfTest {
    static func processList(session: Session) async {
        guard let client = session.client, let sleeper = try? await client.secondConnection(),
              let idle = try? await client.secondConnection() else { return check("S-053 connected", false) }
        let started = ContinuousClock.now
        let sleeping = Task { _ = try? await sleeper.run("SELECT SLEEP(30) AS quarry_selftest_sleep") }
        try? await Task.sleep(for: .seconds(0.5))

        let list = ProcessList(server: "Local", source: client)
        ProcessList.open[list.id] = list
        await list.start()
        let sleepID = sleeper.connectionID.map(Int64.init)
        check("S-053 the list shows every connection, the SLEEP as a Query",
              list.processes.contains { $0.id == sleepID && $0.command == "Query" && $0.info?.contains("SLEEP") == true }
                  && list.processes.contains { $0.id == list.ownConnectionID }
                  && list.processes.contains { $0.id == list.windowConnectionID },
              list.error?.message ?? list.processes.map { "\($0.id) \($0.command)" }.joined(separator: ", "))

        list.search = "quarry_selftest_sleep"
        check("S-053 the filter narrows the list and counts N of M",
              list.shown.map(\.id) == [sleepID].compactMap { $0 } && list.countText == "1 of \(list.processes.count)",
              list.countText)
        list.selection = Set(list.shown.map(\.id))

        list.requestKill(connection: false)
        check("S-053 Kill Query asks first, naming the connection",
              list.pendingKill?.id == sleepID && list.pendingKill?.connection == false
                  && list.killTitle == "Kill Query on Connection \(sleepID ?? 0)?")
        list.pendingKill = nil
        try? await Task.sleep(for: .seconds(0.3))
        check("S-053 Cancel in the alert kills nothing", list.processes.contains { $0.id == sleepID })

        list.requestKill(connection: false)
        await list.confirmKill()?.value
        _ = await sleeping.value
        let waited = ContinuousClock.now - started
        let alive = (try? await sleeper.run("SELECT 1 AS one"))?.string(0, "one") == "1"
        check("S-053 Kill Query stops the SLEEP and keeps the connection",
              waited < .seconds(10) && list.killError == nil && alive, "\(waited)")

        list.search = ""
        let idleID = idle.connectionID.map(Int64.init)
        list.selection = Set([idleID].compactMap { $0 })
        check("S-053 Kill Query is off for an idle connection, Kill Connection is on",
              !list.canKill(connection: false) && list.canKill(connection: true))
        list.requestKill(connection: true)
        await list.confirmKill()?.value
        check("S-053 Kill Connection closes it", !list.processes.contains { $0.id == idleID } && list.killError == nil,
              list.killError?.message ?? "")
        list.stop()
        check("S-053 closing the list closes its connection", list.isClosed && ProcessList.open[list.id] == nil)
        await sleeper.close()
        await idle.close()

        // ⌥⌘P opens the window; again brings the same one forward; closing it stops its list.
        session.requestProcessList()
        await until { NSApp.windows.contains { $0.isVisible && $0.title == "Server Processes" } }
        for _ in 0..<50 where !NSApp.windows.contains(where: { $0.isVisible && $0.title == "Server Processes" }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let firstID = session.processListID
        session.requestProcessList()
        try? await Task.sleep(for: .seconds(0.3))
        let windows = NSApp.windows.filter { $0.isVisible && $0.title == "Server Processes" }
        check("S-053 ⌥⌘P opens one Server Processes window, and again brings it forward",
              windows.count == 1 && firstID != nil && session.processListID == firstID, "\(windows.count) windows")
        windows.forEach { $0.close() }
        try? await Task.sleep(for: .seconds(0.3))
        check("S-053 closing the window closes its connection", firstID.map { ProcessList.open[$0] == nil } ?? false)
        session.processListID = nil
    }
}
