import AppKit
import QuarryKit

/// Self-test: Import a SQL file (S-044).
extension SelfTest {
    static func importing(session: Session) async {
        guard let client = session.client else { return check("S-044 connected", false) }
        session.database = "quarry_demo"
        await session.currentLoad?.value
        session.view = .content
        session.selectedObjectID = "table:orders"
        await session.currentLoad?.value

        await until { menuItem("Import…")?.isEnabled == true }
        let item = menuItem("Import…")
        check("S-044 File > Import… is ⇧⌘I and on while connected",
              item?.keyEquivalent.lowercased() == "i" && item?.keyEquivalentModifierMask == [.command, .shift]
              && item?.isEnabled == true && item?.menu?.title == "File",
              "\(item?.keyEquivalent ?? "-") \(item?.keyEquivalentModifierMask.rawValue ?? 0) \(item?.menu?.title ?? "")")

        // The S-041 export of quarry_demo, gzipped, imported into a new database.
        session.requestExport()
        guard let exporter = session.exporter else { return check("S-044 an export to import", false) }
        exporter.compression = .gzip
        let dump = URL(filePath: NSTemporaryDirectory()).appending(path: "quarry-selftest-import.sql.gz")
        try? FileManager.default.removeItem(at: dump)
        await exporter.start(to: dump)?.value
        session.exporter = nil
        check("S-044 the export to import was written", FileManager.default.fileExists(atPath: dump.path), exporter.error ?? "")

        let target = "quarry_selftest_import"
        _ = try? await client.run("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target))
        _ = try? await client.run("CREATE DATABASE " + SQLQuote.identifier(target))
        session.database = target
        await session.currentLoad?.value
        session.requestImport(file: dump)
        guard let importer = session.importer else { return check("S-044 the Import sheet opens", false) }
        check("S-044 the sheet names the database and the file",
              importer.title == "Import into \u{201C}\(target)\u{201D}" && importer.canImport
              && importer.fileSummary?.hasPrefix("quarry-selftest-import.sql.gz, ") == true
              && !session.menuSnapshot.canImport,
              "\(importer.title) \(importer.fileSummary ?? "")")
        try? await Task.sleep(for: .seconds(1))
        let job = importer.start()
        // Its own connection: the window answers while it runs.
        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<5 {
            let asked = clock.now
            _ = try? await client.run("SELECT 1")
            times.append(clock.now - asked)
        }
        let waited = times.dropFirst().max() ?? .zero
        let wasRunning = importer.isWorking
        await job?.value
        let tables = (try? await client.objects(in: "quarry_demo"))?.filter { $0.kind == .table }.map(\.name) ?? []
        let before = (try? await client.fingerprint(of: tables, in: "quarry_demo")) ?? [:]
        let after = (try? await client.fingerprint(of: tables, in: target)) ?? [:]
        let original = Set((try? await client.objects(in: "quarry_demo")) ?? [])
        let copied = Set((try? await client.objects(in: target)) ?? [])
        check("S-044 importing the S-041 export reproduces the database (row counts, checksums, every object)",
              importer.error == nil && importer.summary?.failures.isEmpty == true && !before.isEmpty
              && before == after && original == copied,
              importer.error ?? "\(importer.summary?.failures.map(\.text) ?? []) \(before.filter { after[$0.key] != $0.value }.keys)")
        check("S-044 browsing doesn't wait for the import", wasRunning && waited < .milliseconds(300), "\(waited)")
        check("S-044 progress counts the whole file's bytes",
              importer.progress.map { $0.bytesRead == $0.totalBytes && $0.totalBytes > 0 && $0.statements > 0 } == true,
              "\(String(describing: importer.progress))")
        check("S-044 the sheet says what ran", importer.finishedText?.hasPrefix("Ran ") == true
              && importer.finishedText?.hasSuffix(" from quarry-selftest-import.sql.gz") == true,
              importer.finishedText ?? "")
        session.closeImport()

        // Errors: Skip goes on, Stop stops, Ask waits for an answer.
        let script = URL(filePath: NSTemporaryDirectory()).appending(path: "quarry-selftest-errors.sql")
        try? """
            CREATE TABLE t (id INT PRIMARY KEY);
            INSERT INTO t VALUES (1);
            INSERT INTO nowhere VALUES (1);
            DELIMITER //
            CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END //
            DELIMITER ;
            INSERT INTO t VALUES (1);
            INSERT INTO t VALUES (2);
            """.write(to: script, atomically: true, encoding: .utf8)
        func run(_ policy: Importer.ErrorPolicy, answer: ImportErrorChoice? = nil) async -> Importer? {
            _ = try? await client.run("DROP TABLE IF EXISTS \(SQLQuote.qualified(target, "t"))")
            _ = try? await client.run("DROP PROCEDURE IF EXISTS \(SQLQuote.qualified(target, "p"))")
            session.requestImport(file: script)
            guard let importer = session.importer else { return nil }
            importer.errorPolicy = policy
            let job = importer.start()
            if let answer {
                for _ in 0..<250 where importer.pendingFailure == nil { try? await Task.sleep(for: .milliseconds(20)) }
                if importer.pendingFailure != nil { importer.answer(answer) }
            }
            await job?.value
            session.importer = nil
            return importer
        }
        let rows = { await firstValue(in: session, "SELECT COUNT(*) FROM \(SQLQuote.qualified(target, "t"))") }
        let skipped = await run(.skip)
        let skippedRows = await rows()
        let procedure = await firstValue(in: session, "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '\(target)' AND ROUTINE_NAME = 'p'")
        check("S-044 Skip It and Continue runs every statement and lists the errors (a DELIMITER block included)",
              skipped?.summary?.statements == 6 && skipped?.summary?.failures.map(\.number) == [3, 5]
              && skippedRows == "2" && procedure == "1",
              "\(skipped?.summary.map { "\($0.statements) \($0.failures.map(\.text))" } ?? skipped?.error ?? "") rows \(skippedRows ?? "-")")
        let stopped = await run(.stop)
        let stoppedRows = await rows()
        check("S-044 Stop the Import ends at the first error",
              stopped?.summary?.stopped == true && stopped?.summary?.statements == 3 && stoppedRows == "1",
              stopped?.finishedText ?? stopped?.error ?? "")
        let asked2 = await run(.ask, answer: .skipAll)
        check("S-044 Ask Me pauses on an error; Skip All Errors goes on without asking again",
              asked2?.summary?.statements == 6 && asked2?.summary?.failures.count == 2 && asked2?.pendingFailure == nil,
              asked2?.summary.map { "\($0.statements) \($0.failures.count)" } ?? "")

        // Cancel stops a running import; what ran stays.
        _ = try? await client.run("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target))
        _ = try? await client.run("CREATE DATABASE " + SQLQuote.identifier(target))
        session.requestImport(file: dump)
        if let cancelling = session.importer {
            let job = cancelling.start()
            for _ in 0..<250 where (cancelling.progress?.statements ?? 0) == 0 { try? await Task.sleep(for: .milliseconds(10)) }
            cancelling.cancel()
            await job?.value
            check("S-044 Cancel stops the import and says how far it got",
                  cancelling.wasCancelled && !cancelling.isWorking && cancelling.summary == nil
                  && cancelling.cancelledText.hasPrefix("Import cancelled after "),
                  "cancelled \(cancelling.wasCancelled), \(cancelling.error ?? "") \(cancelling.finishedText ?? "")")
        }
        session.importer = nil
        _ = try? await client.run("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target))
        try? FileManager.default.removeItem(at: dump)
        try? FileManager.default.removeItem(at: script)
        session.database = "quarry_demo"
        await session.currentLoad?.value
    }
}
