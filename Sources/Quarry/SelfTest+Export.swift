import AppKit
import QuarryKit

/// Self-test: Export (S-041).
extension SelfTest {
    static func export(session: Session) async {
        guard let client = session.client else { return check("S-041 connected", false) }
        session.database = "quarry_demo"
        await session.currentLoad?.value
        session.view = .content
        session.selectedObjectID = "table:orders"
        session.sidebarSelection = ["table:orders"]
        await session.currentLoad?.value

        let item = menuItem("Export…")
        check("S-041 File > Export… is ⇧⌘E and on with a database open",
              item?.keyEquivalent.lowercased() == "e" && item?.keyEquivalentModifierMask == [.command, .shift]
              && item?.isEnabled == true && item?.menu?.title == "File",
              "\(item?.keyEquivalent ?? "-") \(item?.keyEquivalentModifierMask.rawValue ?? 0) \(item?.menu?.title ?? "")")
        let fieldEditor = menuItem("Open in Field Editor")
        check("S-041 Open in Field Editor moved to ⌃⌘E",
              fieldEditor?.keyEquivalent == "e" && fieldEditor?.keyEquivalentModifierMask == [.command, .control])

        // From the row menu: only the clicked object starts checked.
        session.requestExport(["table:orders"])
        guard let one = session.exporter else { return check("S-041 Export… opens the sheet", false) }
        check("S-041 the sheet lists every object and checks only the clicked one",
              one.rows.count == session.objects.count && one.items.map(\.object.name) == ["orders"]
              && one.fileName == "orders.sql" && one.title == "Export “quarry_demo”",
              "\(one.items.map(\.object.name)) \(one.fileName)")
        check("S-041 a view has no Content to write",
              one.rows.first { $0.object.kind == .view }?.hasContent == false)
        check("S-041 Export… is off in the menu while the sheet is open", !session.menuSnapshot.canExport)
        one.setAll(false)
        check("S-041 nothing checked: Export… is off", !one.canExport)
        session.exporter = nil

        // File > Export…: everything, exported and loaded into a new database.
        session.sidebarSelection = []
        session.requestExport()
        guard let exporter = session.exporter else { return check("S-041 ⇧⌘E opens the sheet", false) }
        check("S-041 from the menu every object starts checked", exporter.items.count == session.objects.count,
              exporter.checkedSummary)
        exporter.batchUnit = .rows
        exporter.batchSize = 2_000
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "quarry-selftest-export.sql")
        try? FileManager.default.removeItem(at: url)
        // The sheet lays out once as it appears; time the export, not that.
        try? await Task.sleep(for: .seconds(1))
        let job = exporter.start(to: url)

        // The export has its own connection: the window's answers at once.
        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<5 {
            let asked = clock.now
            _ = try? await client.run("SELECT 1")
            times.append(clock.now - asked)
        }
        print("S-041 timings \(times)")
        let waited = times.dropFirst().max() ?? .zero
        let stillRunning = exporter.isWorking
        await job?.value
        check("S-041 browsing doesn't wait for the export", waited < .milliseconds(300) && stillRunning,
              "\(waited), running \(stillRunning)")
        check("S-041 the export finishes and says where",
              exporter.finishedFile == url && exporter.finishedText == "Exported \(session.objects.count) items to quarry-selftest-export.sql"
              && FileManager.default.fileExists(atPath: url.path), exporter.error ?? "")

        let target = "quarry_selftest_export"
        let tables = session.objects.filter { $0.kind == .table }.map(\.name)
        _ = try? await client.run("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target))
        _ = try? await client.run("CREATE DATABASE " + SQLQuote.identifier(target))
        var loadError = ""
        do {
            try await client.runScript(try String(contentsOf: url, encoding: .utf8), in: target)
        } catch {
            loadError = DatabaseError.from(error).message
        }
        let before = (try? await client.fingerprint(of: tables, in: "quarry_demo")) ?? [:]
        let after = (try? await client.fingerprint(of: tables, in: target)) ?? [:]
        let copied = (try? await client.objects(in: target)) ?? []
        check("S-041 importing the export into a new database gives identical row counts and checksums",
              loadError.isEmpty && !before.isEmpty && before == after && Set(copied) == Set(session.objects),
              loadError.isEmpty ? "\(before.filter { after[$0.key] != $0.value })" : loadError)
        _ = try? await client.run("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target))
        _ = try? await client.use("quarry_demo")
        try? FileManager.default.removeItem(at: url)

        // Cancel deletes the unfinished file.
        let cancelled = exporter.start(to: url)
        exporter.cancel()
        await cancelled?.value
        check("S-041 Cancel stops the export and deletes the unfinished file",
              exporter.wasCancelled && !FileManager.default.fileExists(atPath: url.path) && exporter.finishedFile == nil,
              "cancelled \(exporter.wasCancelled), error \(exporter.error ?? "none")")
        session.exporter = nil

        // Cancel stops a slow SELECT on the server, not after it returns.
        let slow = "quarry_selftest_slow"
        _ = try? await client.run("CREATE OR REPLACE VIEW \(SQLQuote.identifier(slow)) AS SELECT id, SLEEP(4) AS waited FROM orders LIMIT 1")
        let waiting = Exporter(database: "quarry_demo", objects: [DBObject(name: slow, kind: .view)], chosen: [],
                               client: client, format: .csv)
        let csvURL = FileManager.default.temporaryDirectory.appending(path: "quarry-selftest-slow.csv")
        let started = ContinuousClock.now
        let slowJob = waiting.start(to: csvURL)
        try? await Task.sleep(for: .milliseconds(500))
        waiting.cancel()
        await slowJob?.value
        let took = ContinuousClock.now - started
        check("S-041 Cancel stops the SELECT running on the server at once",
              waiting.wasCancelled && took < .seconds(2) && !FileManager.default.fileExists(atPath: csvURL.path),
              "took \(took), cancelled \(waiting.wasCancelled), error \(waiting.error ?? "none")")
        _ = try? await client.run("DROP VIEW IF EXISTS \(SQLQuote.identifier(slow))")
    }
}
