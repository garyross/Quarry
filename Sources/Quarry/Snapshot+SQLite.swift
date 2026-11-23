import AppKit
import QuarryKit

/// Snapshot pages for SQLite files (S-068), on a copy of tools/fixture-sqlite.sql in /tmp.
extension SnapshotPage {
    /// One fixture per run, made the first time a SQLite page asks.
    @MainActor private static var sqliteFixture: URL?

    @MainActor
    func prepareSQLite(_ session: Session, model: AppModel) async {
        if Self.sqliteFixture == nil { Self.sqliteFixture = SelfTest.makeSQLiteFixture() }
        guard let url = Self.sqliteFixture else { return }
        let details = ConnectionDetails(transport: .sqlite, file: (url.path as NSString).abbreviatingWithTildeInPath)
        switch self {
        case .connectSQLite:
            // The Connect form with SQLite File chosen and a file filled in.
            session.disconnect()
            session.show(saved: nil)
            session.form = details
        default:
            if !session.isSQLite {
                session.disconnect()
                session.show(saved: nil)
                session.form = details
                session.connect(model: model)
                await session.waitForConnect()
                await session.currentLoad?.value
            }
            if self == .sqliteContent {
                session.selectedObjectID = "table:orders"
                session.view = .content
                await session.currentLoad?.value
            } else if self == .sqliteExport {
                // S-071: the Export sheet on a file, without MySQL's options.
                session.selectedObjectID = "table:orders"
                session.view = .content
                await session.currentLoad?.value
                session.sidebarSelection = []
                session.requestExport()
            } else if self == .sqliteDatabaseInfo {
                // S-072: the panel on a file, with the Health Check's findings.
                session.selectedObjectID = "table:orders"
                session.view = .structure
                await session.currentLoad?.value
                await session.runTool(.health)?.value
            } else if self == .sqliteStructure || self == .sqliteFieldSheet {
                // S-070: SQLite's fields, without Length, Unsigned or Comment; the Edit Field sheet on email.
                session.selectedObjectID = "table:customers"
                session.view = .structure
                await session.currentLoad?.value
                if self == .sqliteFieldSheet {
                    session.structure.selection = [2]
                    session.requestEditField()
                    session.structure.fieldSheet?.collation = "NOCASE"
                }
            } else if self == .sqliteNewForeignKey {
                // The Add Foreign Key sheet on a file: its footer shows the rebuild, not MySQL's ALTER TABLE.
                session.selectedObjectID = "table:notes"
                session.view = .foreignKeys
                await session.currentLoad?.value
                session.requestAddForeignKey()
                await session.currentLoad?.value
            } else if self == .sqliteInfo {
                // S-070: a WITHOUT ROWID table's options.
                session.selectedObjectID = "table:settings"
                session.view = .info
                await session.currentLoad?.value
            } else if self == .sqliteNotesInfo {
                // S-069: a table with no primary key says its rows are found by rowid.
                session.selectedObjectID = "table:notes"
                session.view = .info
                await session.currentLoad?.value
            } else {
                session.view = .query
                session.query.text = "SELECT c.name, COUNT(o.id) AS orders, ROUND(SUM(i.quantity * i.unit_price), 2) AS spent\n"
                    + "FROM customers c\nLEFT JOIN orders o ON o.customer_id = c.id\nLEFT JOIN order_items i ON i.order_id = o.id\n"
                    + "GROUP BY c.id\nORDER BY spent DESC;"
                session.runAll()
                await session.currentLoad?.value
            }
        }
    }
}
