import AppKit
import QuarryKit

/// Self-test: Import a CSV file into a table (S-045).
extension SelfTest {
    static func csvImporting(session: Session) async {
        guard let client = session.client else { return check("S-045 connected", false) }
        let target = "quarry_selftest_csv"
        _ = try? await client.run("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target))
        _ = try? await client.run("CREATE DATABASE " + SQLQuote.identifier(target))
        _ = try? await client.run("CREATE TABLE \(SQLQuote.qualified(target, "people")) "
                                  + "(id INT PRIMARY KEY, name VARCHAR(80), amount DECIMAL(10,2), note TEXT NULL)")
        session.database = target
        await session.currentLoad?.value
        session.view = .content
        session.selectedObjectID = "table:people"
        await session.currentLoad?.value

        // 10 000 records, columns in another order than the table's, with
        // quoted commas, doubled quotes, line breaks and NULLs.
        var text = "Name,ID,Amount,Note\n"
        for id in 1...10_000 {
            let note = id % 10 == 0 ? "NULL" : id % 7 == 0 ? "\"line one\nline \"\"two\"\"\"" : "\"note, \(id)\""
            text += "\"Person \(id)\",\(id),\(id).50,\(note)\n"
        }
        let file = URL(filePath: NSTemporaryDirectory()).appending(path: "quarry-selftest-people.csv")
        try? text.write(to: file, atomically: true, encoding: .utf8)

        session.requestImport(file: file)
        guard let importer = session.importer else { return check("S-045 the Import sheet opens", false) }
        check("S-045 a .csv file opens the sheet as CSV", importer.format == .csv && !importer.isMapping && importer.canGoNext,
              "\(importer.format) \(importer.canGoNext)")
        await importer.next()
        let csv = importer.csv
        check("S-045 Next maps the selected table's fields by matching names",
              importer.isMapping && csv.target == .table("people") && csv.alignment == .matchingNames
              && csv.mapping.sources == [1, 0, 2, 3] && csv.columns == ["Name", "ID", "Amount", "Note"]
              && csv.recordText == "Record 1 of the first 100" && csv.previewValue(for: 1) == "Person 1",
              "\(csv.target) \(csv.alignment) \(csv.mapping.sources) \(csv.columns) \(csv.recordText) \(csv.loadError ?? "")")
        csv.align(.fileOrder)
        check("S-045 File Order lines columns up by position", csv.mapping.sources == [0, 1, 2, 3])
        csv.align(.matchingNames)
        csv.setSource(nil, for: 3)
        check("S-045 picking a column by hand makes the order custom", csv.alignment == .custom && csv.mapping.sources[3] == nil)
        csv.setSource(3, for: 3)

        await importer.start()?.value
        let count = await firstValue(in: session, "SELECT COUNT(*) FROM \(SQLQuote.qualified(target, "people"))")
        let sample = await firstValue(in: session, "SELECT CONCAT_WS('|', name, amount, IFNULL(note, 'null')) "
                                      + "FROM \(SQLQuote.qualified(target, "people")) WHERE id = 7")
        let nulls = await firstValue(in: session, "SELECT COUNT(*) FROM \(SQLQuote.qualified(target, "people")) WHERE note IS NULL")
        check("S-045 importing 10 000 rows finishes with the right count",
              importer.summary?.rows == 10_000 && importer.summary?.failures.isEmpty == true && count == "10000"
              && importer.finishedText == "Imported 10,000 rows into \u{201C}people\u{201D}",
              "\(importer.error ?? "") \(importer.summary?.failures.map(\.text) ?? []) count \(count ?? "-") \(importer.finishedText ?? "")")
        check("S-045 quoted commas, doubled quotes, line breaks and NULL arrive intact",
              sample == "Person 7|7.50|line one\nline \"two\"" && nulls == "1000", "\(sample ?? "-") nulls \(nulls ?? "-")")

        // Again with INSERT: every row is a duplicate; Skip It and Continue lists batches.
        importer.errorPolicy = .skip
        await importer.start()?.value
        check("S-045 a failed batch is named by its rows",
              importer.summary?.rows == 0 && importer.summary?.failures.first?.text.hasPrefix("Rows 1–1,000: ") == true
              && importer.summary?.failures.count == 10,
              importer.summary?.failures.first?.text ?? importer.error ?? "")
        csv.setIgnoreDuplicates(true)
        await importer.start()?.value
        check("S-045 Skip rows whose key exists runs INSERT IGNORE", importer.summary?.failures.isEmpty == true,
              importer.summary?.failures.first?.text ?? "")

        // UPDATE by the Match field: two names change.
        let update = URL(filePath: NSTemporaryDirectory()).appending(path: "quarry-selftest-update.csv")
        try? "id,name\n3,Renamed Three\n4,Renamed Four\n".write(to: update, atomically: true, encoding: .utf8)
        importer.choose(update)
        await importer.next()
        csv.setMethod(.update)
        check("S-045 UPDATE matches on the primary key by default",
              csv.mapping.matchFields == ["id"] && csv.mapping.sources == [0, 1, nil, nil] && csv.problem == nil,
              "\(csv.mapping.matchFields) \(csv.mapping.sources) \(csv.problem ?? "")")
        await importer.start()?.value
        let renamed = await firstValue(in: session, "SELECT GROUP_CONCAT(name ORDER BY id) FROM \(SQLQuote.qualified(target, "people")) WHERE id IN (3, 4)")
        check("S-045 UPDATE changes the matched rows", renamed == "Renamed Three,Renamed Four" && importer.summary?.rows == 2,
              renamed ?? importer.error ?? "")

        // A new table from a tab-separated file, its types guessed.
        let tsv = URL(filePath: NSTemporaryDirectory()).appending(path: "quarry-selftest-scores.tsv")
        try? "player\tscore\tplayed\nAnn\t12\t2026-11-19\nBob\t7\t2026-11-18\n".write(to: tsv, atomically: true, encoding: .utf8)
        importer.choose(tsv)
        await importer.next()
        importer.chooseTarget(.newTable)
        await until { !csv.isLoading && csv.isNewTable }
        check("S-045 New Table guesses each field's type",
              csv.format.separator == .tab && csv.newTableName == "quarry_selftest_scores"
              && csv.newFields.map(\.type) == ["VARCHAR(255)", "INT", "DATE"] && csv.problem == nil,
              "\(csv.newTableName) \(csv.newFields.map(\.type)) \(csv.problem ?? "")")
        csv.newTableName = "scores"
        await importer.start()?.value
        let scores = await firstValue(in: session, "SELECT SUM(score) FROM \(SQLQuote.qualified(target, "scores"))")
        check("S-045 New Table makes the table and imports into it", scores == "19", scores ?? importer.error ?? "")

        session.importer = nil
        _ = try? await client.run("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target))
        for url in [file, update, tsv] { try? FileManager.default.removeItem(at: url) }
        session.database = "quarry_demo"
        await session.currentLoad?.value
    }
}
