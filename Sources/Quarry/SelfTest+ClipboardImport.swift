import AppKit
import QuarryKit

/// Self-test: Import from Clipboard (S-046). The text is passed in, so the
/// test never touches the person's clipboard.
extension SelfTest {
    static func clipboardImporting(session: Session) async {
        guard let client = session.client else { return check("S-046 connected", false) }
        let target = "quarry_selftest_clipboard"
        _ = try? await client.run("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target))
        _ = try? await client.run("CREATE DATABASE " + SQLQuote.identifier(target))
        _ = try? await client.run("CREATE TABLE \(SQLQuote.qualified(target, "people")) "
                                  + "(id INT PRIMARY KEY, name VARCHAR(80), city VARCHAR(80))")
        session.database = target
        await session.currentLoad?.value
        session.view = .content
        session.selectedObjectID = "table:people"
        await session.currentLoad?.value

        // Cells copied from a spreadsheet: tabs between columns, a header row,
        // the columns in another order than the table's.
        let cells = "Name\tCity\tID\nZoë Martin\tLyon\t1\nKenji Sato\tŌsaka\t2\nAna Lima\tRecife\t3\n"
        session.importFromClipboard(cells)
        guard let importer = session.importer else { return check("S-046 the Import sheet opens", false) }
        let file = importer.file
        check("S-046 spreadsheet cells open as CSV with Tab, previewed",
              importer.clipboard == cells && importer.format == .csv && importer.csv.format.separator == .tab
              && importer.fileSummary == "4 lines, 70 bytes" && importer.canGoNext,
              "\(importer.format) \(importer.csv.format.separator) \(importer.fileSummary ?? "")")
        await importer.next()
        let csv = importer.csv
        check("S-046 tab-separated text maps to the table's columns",
              importer.isMapping && csv.target == .table("people") && csv.columns == ["Name", "City", "ID"]
              && csv.mapping.sources == [2, 0, 1] && csv.problem == nil,
              "\(csv.target) \(csv.columns) \(csv.mapping.sources) \(csv.loadError ?? "")")
        await importer.start()?.value
        let rows = await firstValue(in: session, "SELECT GROUP_CONCAT(CONCAT(id, name, city) ORDER BY id SEPARATOR '|') "
                                    + "FROM \(SQLQuote.qualified(target, "people"))")
        check("S-046 the rows arrive, and the result names the clipboard",
              rows == "1Zoë MartinLyon|2Kenji SatoŌsaka|3Ana LimaRecife"
              && importer.finishedText == "Imported 3 rows into \u{201C}people\u{201D}",
              "\(rows ?? importer.error ?? "-") \(importer.finishedText ?? "")")
        session.closeImport()
        check("S-046 closing the sheet removes the temporary file",
              session.importer == nil && file.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
        await session.currentLoad?.value

        // SQL statements run as SQL.
        session.importFromClipboard("-- copied\nINSERT INTO people VALUES (4, 'Lea', 'Graz');\nDELETE FROM people WHERE id = 1;\n")
        guard let sql = session.importer else { return check("S-046 SQL opens the sheet", false) }
        check("S-046 statements open as SQL", sql.format == .sql && sql.canImport, "\(sql.format)")
        await sql.start()?.value
        let count = await firstValue(in: session, "SELECT GROUP_CONCAT(id ORDER BY id) FROM \(SQLQuote.qualified(target, "people"))")
        check("S-046 the statements run", count == "2,3,4" && sql.finishedText == "Ran 2 statements from the clipboard",
              "\(count ?? sql.error ?? "-") \(sql.finishedText ?? "")")
        session.closeImport()
        await session.currentLoad?.value

        _ = try? await client.run("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target))
        session.database = "quarry_demo"
        await session.currentLoad?.value
    }
}
