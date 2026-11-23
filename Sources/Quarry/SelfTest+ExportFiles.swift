import AppKit
import QuarryKit

/// Self-test: file name patterns and one file per table (S-043).
extension SelfTest {
    static func exportFiles(session: Session) async {
        session.database = "quarry_demo"
        await session.currentLoad?.value
        session.view = .content
        session.sidebarSelection = []
        session.requestExport(["table:customers", "table:products", "view:order_totals"])
        guard let exporter = session.exporter else { return check("S-043 Export… opens the sheet", false) }

        // A pattern names the single file.
        exporter.namePattern = "backup_"
        exporter.insert(.database)
        check("S-043 a token goes into the name and the name expands",
              exporter.namePattern == "backup_{database}" && exporter.fileName == "backup_quarry_demo.sql"
              && exporter.canSplit && !exporter.splitsFiles,
              "\(exporter.namePattern) \(exporter.fileName)")

        // One file per table: each its own file, named by the pattern plus the table.
        let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "quarry-selftest-split", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        exporter.namePattern = "{table}_{database}"
        exporter.perTable = true
        let expected = ["customers_quarry_demo.sql", "products_quarry_demo.sql", "order_totals_quarry_demo.sql"]
        check("S-043 one file per table lists a file for each item",
              exporter.splitsFiles && exporter.perTableNames().map(\.file) == expected,
              "\(exporter.perTableNames().map(\.file))")
        await exporter.start(to: folder)?.value
        let written = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let customers = (try? String(contentsOf: folder.appending(path: expected[0]), encoding: .utf8)) ?? ""
        check("S-043 each item is written to its own whole file",
              written == Set(expected) && customers.contains("CREATE TABLE `customers`")
              && !customers.contains("`products`") && customers.contains("SET NAMES utf8mb4")
              && exporter.finishedText == "Exported 3 items to 3 files in quarry-selftest-split"
              && exporter.existingFiles(in: folder).count == 3,
              "\(written.sorted()) \(exporter.error ?? exporter.finishedText ?? "")")

        // CSV per table: one header per file.
        exporter.format = .csv
        exporter.namePattern = ""
        await exporter.start(to: folder)?.value
        let products = (try? String(contentsOf: folder.appending(path: "products.csv"), encoding: .utf8)) ?? ""
        check("S-043 CSV per table writes each table with its header",
              products.hasPrefix("\"id\",") && products.components(separatedBy: "\n\n").count == 1
              && FileManager.default.fileExists(atPath: folder.appending(path: "customers.csv").path),
              exporter.error ?? String(products.prefix(80)))

        // Cancel leaves none of the files behind.
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        exporter.format = .sql
        let job = exporter.start(to: folder)
        exporter.cancel()
        await job?.value
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        check("S-043 Cancel stops a per-table export and removes its files",
              exporter.wasCancelled && left.isEmpty && exporter.finishedFile == nil,
              "\(left) cancelled \(exporter.wasCancelled)")
        session.exporter = nil
    }
}
