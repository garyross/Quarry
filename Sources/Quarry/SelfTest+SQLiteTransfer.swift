import AppKit
import QuarryKit

/// S-071: export and import with a SQLite file, on the tab `sqliteFiles` opened.
/// Exports the fixture as SQL (read back by /usr/bin/sqlite3 and by Import),
/// one file per table, CSV, JSON and XML; imports CSV and the clipboard.
extension SelfTest {
    static func sqliteTransfer(_ tab: Session, model: AppModel) async {
        guard let source = makeSQLiteFixture() else { return check("S-071 a SQLite fixture to export", false) }
        let folder = source.deletingLastPathComponent()
        await openSQLite(tab, source, model: model)
        guard tab.phase == .connected else { return check("S-071 the fixture opens", false, tab.connectProblem?.message ?? "") }
        check("S-071 Export… and Import… are on for a SQLite file", tab.menuSnapshot.canExport && tab.menuSnapshot.canImport,
              "\(tab.connectionName) \(tab.objects.count) \(tab.database ?? "nil")")

        // Export as SQL: SQLite's options only.
        tab.requestExport()
        guard let exporter = tab.exporter else { return check("S-071 the Export sheet opens", false) }
        check("S-071 MySQL-only export options don't show for SQLite (auto-increment, BLOBs as hex)",
              !exporter.showsServerOptions && exporter.title == "Export \u{201C}quarry_demo.sqlite\u{201D}"
                  && exporter.fileName == "quarry_demo.sql"
                  && exporter.rows.allSatisfy { $0.object.kind == .table || $0.object.kind == .view })
        let dump = folder.appending(path: "export.sql")
        await exporter.start(to: dump)?.value
        let text = (try? String(contentsOf: dump, encoding: .utf8)) ?? ""
        check("S-071 Export as SQL writes CREATE from sqlite_schema, INSERTs, BLOBs as X'…' and sqlite_sequence",
              exporter.error == nil && text.contains("PRAGMA foreign_keys = OFF;") && text.contains("CREATE TABLE settings")
                  && text.contains("X'89504E470D0A1A0A'") && text.contains("INSERT INTO sqlite_sequence (name, seq) VALUES ('customers', 6);")
                  && text.contains("CREATE TRIGGER products_stock_check") && !text.contains("LOCK TABLES"),
              exporter.error ?? String(text.prefix(300)))
        tab.exporter = nil

        // sqlite3 reads it back into a new file with the same rows.
        let copy = folder.appending(path: "sqlite3-copy.sqlite")
        let (status, errors) = runSQLite3(copy, input: dump)
        check("S-071 sqlite3 reads the export back without an error", status == 0 && errors.isEmpty, errors)
        let same = await sameRows(source, copy)
        check("S-071 the file sqlite3 made has the same rows, stored types and sequence", same == nil, same ?? "")

        // One file per table, named by tokens.
        tab.requestExport()
        if let split = tab.exporter {
            split.namePattern = "{table}_{database}"
            split.perTable = true
            let out = folder.appending(path: "per-table", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            await split.start(to: out)?.value
            let files = (try? FileManager.default.contentsOfDirectory(atPath: out.path))?.sorted() ?? []
            let (alone, aloneErrors) = runSQLite3(folder.appending(path: "customers-only.sqlite"),
                                                  input: out.appending(path: "customers_quarry_demo.sql"))
            check("S-071 One file per table writes a file for each item, named by tokens, each loading on its own",
                  split.error == nil && files.count == split.items.count && files.contains("customers_quarry_demo.sql") && alone == 0,
                  split.error ?? aloneErrors + files.joined(separator: ", "))
            tab.exporter = nil
        }

        // CSV, JSON and XML as on a server.
        for format in [Exporter.Format.csv, .json, .xml] {
            tab.requestExport(format: format)
            guard let data = tab.exporter else { continue }
            let file = folder.appending(path: "export.\(format.rawValue)")
            await data.start(to: file)?.value
            let written = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            check("S-071 Export as \(format.title) writes the file's rows", data.error == nil && written.contains("Ada Lovelace"),
                  data.error ?? String(written.prefix(200)))
            tab.exporter = nil
        }

        // Import the SQL export into an empty file through the Import sheet.
        let target = folder.appending(path: "Imported.sqlite")
        tab.disconnect()
        await tab.createSQLiteFile(at: target, replacing: false)?.value
        await tab.currentLoad?.value
        tab.requestImport(file: dump)
        guard let importer = tab.importer else { return check("S-071 the Import sheet opens on a SQLite file", false) }
        await importer.start()?.value
        let imported = await sameRows(source, target)
        check("S-071 Import a SQL file loads the export into an empty SQLite file, row for row",
              importer.error == nil && importer.summary?.failures.isEmpty == true && imported == nil,
              importer.error ?? "\(importer.summary?.failures.map(\.text) ?? []) \(imported ?? "")")
        tab.closeImport()
        await tab.currentLoad?.value

        // A DELIMITER line is refused with its line number.
        let delimited = folder.appending(path: "delimiter.sql")
        try? "CREATE TABLE d (a);\n\nDELIMITER ;;\nINSERT INTO d VALUES (1);;\n".write(to: delimited, atomically: true, encoding: .utf8)
        tab.requestImport(file: delimited)
        if let refused = tab.importer {
            await refused.start()?.value
            check("S-071 a DELIMITER line is refused with its line number",
                  refused.error?.contains("Line 3 sets a DELIMITER") == true, refused.error ?? "no error")
            tab.closeImport()
            await tab.currentLoad?.value
        }

        // Import a CSV file into a new table: SQLite types, values with quotes and backslashes.
        let csv = folder.appending(path: "people.csv")
        try? "name,score,joined\nAnn,12,2026-11-19\n\"O'Neil \\ Jr\",7.5,2026-11-18\n".write(to: csv, atomically: true, encoding: .utf8)
        tab.requestImport(file: csv)
        if let csvImport = tab.importer {
            await csvImport.next()
            csvImport.chooseTarget(.newTable)
            await until { !csvImport.csv.isLoading && csvImport.csv.isNewTable }
            check("S-071 New Table guesses SQLite types", csvImport.csv.newFields.map(\.type) == ["TEXT", "REAL", "TEXT"],
                  "\(csvImport.csv.newFields.map(\.type))")
            csvImport.csv.newTableName = "people"
            await csvImport.start()?.value
            let name = await firstValue(in: tab, "SELECT name FROM people WHERE score = 7.5")
            check("S-071 Import a CSV file maps into a SQLite table", csvImport.summary?.rows == 2 && name == "O'Neil \\ Jr",
                  name ?? csvImport.error ?? "")
            tab.closeImport()
            await tab.currentLoad?.value
        }

        // Content's filter quotes for SQLite: an apostrophe and a backslash match literally.
        await until { tab.objects.contains { $0.name == "people" } }
        tab.view = .content
        tab.selectedObjectID = "table:people"
        await tab.currentLoad?.value
        tab.content.filter.draft = FilterTree(RowFilter(column: "name", op: .contains, value: "O'Neil \\"))
        await tab.content.filter.apply()?.value
        check("S-071 a filter with a quote and a backslash finds the row in a SQLite file",
              tab.content.grid.rows.count == 1 && tab.content.load.error == nil,
              tab.content.load.error?.message ?? "\(tab.content.grid.rows.count) rows")
        tab.content.filter.draft = FilterTree(RowFilter(column: "name"))
        await tab.content.filter.apply()?.value

        // Import from Clipboard, CSV guessed, into a new table.
        tab.importFromClipboard("x,y\n1,a\n2,b\n")
        if let clip = tab.importer {
            await clip.next()
            clip.chooseTarget(.newTable)
            await until { !clip.csv.isLoading && clip.csv.isNewTable }
            await clip.start()?.value
            let letters = await firstValue(in: tab, "SELECT group_concat(y, '') FROM clipboard")
            check("S-071 Import from Clipboard goes into a SQLite table", clip.format == .csv && letters == "ab",
                  clip.error ?? letters ?? "")
            tab.closeImport()
        }
        tab.disconnect()
    }

    static func openSQLite(_ tab: Session, _ url: URL, model: AppModel) async {
        if tab.phase == .connected { tab.disconnect() }
        tab.show(saved: nil)
        tab.form = ConnectionDetails(transport: .sqlite, file: url.path)
        tab.connect(model: model)
        await tab.waitForConnect()
        await tab.currentLoad?.value
        await until { !tab.objects.isEmpty }
    }

    /// Runs /usr/bin/sqlite3 on `file` with `input` as its script: the exit status and what it printed to stderr.
    private static func runSQLite3(_ file: URL, input: URL) -> (Int32, String) {
        guard let handle = FileHandle(forReadingAtPath: input.path) else { return (-1, "no \(input.lastPathComponent)") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-bail", file.path]
        process.standardInput = handle
        let errors = Pipe()
        process.standardError = errors
        guard (try? process.run()) != nil else { return (-1, "sqlite3 didn't start") }
        process.waitUntilExit()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, text)
    }

    /// Nil when both files hold the same tables, views, rows (with their stored types) and sequence; else what differs.
    private static func sameRows(_ one: URL, _ other: URL) async -> String? {
        guard let a = try? await DatabaseClient.connect(ConnectionDetails(transport: .sqlite, file: one.path, readOnly: true))
        else { return "\(one.lastPathComponent) didn't open" }
        guard let b = try? await DatabaseClient.connect(ConnectionDetails(transport: .sqlite, file: other.path, readOnly: true)) else {
            await a.close()
            return "\(other.lastPathComponent) didn't open"
        }
        let difference = await difference(a, b)
        await a.close()
        await b.close()
        return difference
    }

    private static func difference(_ a: DatabaseClient, _ b: DatabaseClient) async -> String? {
        let objects = (try? await a.tablesAndViews(in: "main")) ?? []
        guard objects == (try? await b.tablesAndViews(in: "main")) else { return "different objects" }
        /// Every row with each value's stored type, in a fixed order.
        func rows(_ client: DatabaseClient, _ table: String) async -> [String]? {
            guard let result = try? await client.run("SELECT * FROM \(SQLQuote.identifier(table))") else { return nil }
            return result.rows.map { "\($0)" }.sorted()
        }
        for table in objects.map(\.name) + ["sqlite_sequence"] {
            let left = await rows(a, table)
            let right = await rows(b, table)
            if left == nil || left != right { return "rows of \(table) differ" }
        }
        let types = "SELECT typeof(revision) FROM settings ORDER BY key"
        if (try? await a.run(types).rows) != (try? await b.run(types).rows) { return "stored types of settings differ" }
        return nil
    }
}
