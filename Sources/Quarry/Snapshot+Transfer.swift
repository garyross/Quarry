import AppKit
import QuarryKit
import SwiftUI

/// Snapshot pages for Export and Import.
extension SnapshotPage {
    /// nil: not one of these pages. true: ready now. false: ready once the session's load ends.
    @MainActor
    func prepareTransfer(_ session: Session, model: AppModel, local: SavedConnection?) async -> Bool? {
        switch self {
        case .export:
            // S-041: every quarry_demo object, the SQL options at their defaults.
            show(.content, "table:orders", in: session)
            await session.currentLoad?.value
            session.sidebarSelection = []
            session.requestExport()
            // S-043: a name pattern, one file per table.
            session.exporter?.namePattern = "{table}_{date}"
            session.exporter?.perTable = true
        case .importSQL, .importError:
            // S-044: a file chosen; for import-error, Ask Me paused on a failed statement.
            show(.content, "table:orders", in: session)
            await session.currentLoad?.value
            let file = URL(filePath: NSTemporaryDirectory()).appending(path: "quarry_demo_backup.sql")
            try? "SELECT 1;\nINSERT INTO missing_table VALUES (1, 'Zoë');\nSELECT 2;\n".write(to: file, atomically: true, encoding: .utf8)
            session.requestImport(file: file)
            if self == .importError, let importer = session.importer {
                importer.start()
                for _ in 0..<250 where importer.pendingFailure == nil { try? await Task.sleep(for: .milliseconds(20)) }
            }
        case .importCSV, .csvMapping:
            // S-045: a CSV file's options; for csv-mapping, customers' fields
            // matched by name, the second record previewed.
            show(.content, "table:customers", in: session)
            await session.currentLoad?.value
            let file = URL(filePath: NSTemporaryDirectory()).appending(path: "new_customers.csv")
            let csv = """
                Name,E-mail,Country,Notes
                "Zoë Martin",zoe@example.com,FR,"Prefers email, not phone"
                "Kenji Sato",kenji@example.jp,JP,NULL
                "Ana Lima",ana@example.br,BR,"Asked about ""bulk"" pricing"
                """
            try? csv.write(to: file, atomically: true, encoding: .utf8)
            session.requestImport(file: file)
            if self == .csvMapping, let importer = session.importer {
                await importer.next()
                importer.csv.step(by: 1)
            }
        case .importClipboard:
            // S-046: cells copied from a spreadsheet, read as CSV with Tab.
            show(.content, "table:customers", in: session)
            await session.currentLoad?.value
            session.importFromClipboard("Name\tE-mail\tCountry\nZoë Martin\tzoe@example.com\tFR\n"
                                        + "Kenji Sato\tkenji@example.jp\tJP\nAna Lima\tana@example.br\tBR\n")
        case .exportCSV:
            // S-042: orders' filtered content as CSV, the options at their defaults.
            show(.content, "table:orders", in: session)
            await session.currentLoad?.value
            session.content.filter.draft = FilterTree(RowFilter(column: "total", op: .greater, value: "10"))
            session.applyFilter()
            await session.content.filter.pending?.value
            await session.currentLoad?.value
            session.sidebarSelection = []
            session.requestExport(source: .content, format: .csv)
        default:
            return nil
        }
        return false
    }
}
