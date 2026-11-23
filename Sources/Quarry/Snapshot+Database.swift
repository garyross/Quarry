import AppKit
import QuarryKit
import QuarryControllers
import SwiftUI

/// Snapshot pages for the sidebar, tabs, databases, tables, views, routines and Database Information.
extension SnapshotPage {
    /// nil: not one of these pages. true: ready now. false: ready once the session's load ends.
    @MainActor
    func prepareDatabase(_ session: Session, model: AppModel, local: SavedConnection?) async -> Bool? {
        switch self {
        case .tableContextMenu:
            // S-022: orders right-clicked, every table action listed.
            show(.content, "table:orders", in: session)
        case .tableRename:
            // S-022: the name edited in place in the sidebar.
            show(.content, "table:orders", in: session)
            await session.currentLoad?.value
            session.requestRenameTable()
            session.renameText = "orders_2026"
        case .duplicateTable:
            // S-022: the suggested name, rows on.
            show(.content, "table:orders", in: session)
            await session.currentLoad?.value
            session.requestDuplicateTable()
        case .deleteTables:
            // S-022: two tables selected, the alert names the count and both.
            show(.content, "table:orders", in: session)
            await session.currentLoad?.value
            session.sidebarSelection = ["table:orders", "table:order_items"]
            session.requestDeleteTables()
        case .createSyntax:
            // S-028: orders' CREATE TABLE, colored, in the sheet.
            show(.content, "table:orders", in: session)
            await session.currentLoad?.value
            await session.requestShowCreateStatement()?.value
        case .newView:
            // S-030: a view typed in, Merge chosen.
            session.view = .content
            session.requestNewDefinition(.view)
            session.definitionDraft?.name = "big_orders"
            session.definitionDraft?.algorithm = .merge
            session.definitionDraft?.text = "SELECT o.id, c.name, o.total\nFROM orders o\nJOIN customers c ON c.id = o.customer_id\nWHERE o.total > 100"
        case .editFunction:
            // S-030: the fixture's order_count, read back for editing.
            show(.info, "function:order_count", in: session)
            await session.currentLoad?.value
            session.requestEditDefinition()
            await session.currentLoad?.value
        case .newTable:
            // S-021: a name typed, Aria chosen, on quarry_demo.
            session.view = .structure
            session.requestNewTable()
            for _ in 0..<50 where session.newTable?.isLoading ?? false {
                try? await Task.sleep(for: .milliseconds(20))
            }
            session.newTable?.name = "notes"
            session.newTable?.engine = "Aria"
        case .newDatabase:
            // S-018: a name typed, latin1 chosen, so the collation menu shows latin1's default.
            session.view = .structure
            session.requestNewDatabase()
            for _ in 0..<50 where session.newDatabase?.catalog == nil {
                try? await Task.sleep(for: .milliseconds(20))
            }
            session.newDatabase?.name = "shop"
            session.newDatabase?.charset = "latin1"
        case .goToDatabase:
            // S-020: "qa" matches the fixture's quarry_* databases, letters bold.
            session.view = .structure
            session.requestGoToDatabase()
            session.goToDatabase?.search = "qa"
        case .duplicateDatabase:
            // S-019: the suggested name, rows on.
            session.view = .structure
            session.requestDatabaseEditor(.duplicate)
        case .changeCharacterSet:
            // S-019: quarry_demo's own character set and collation.
            session.view = .structure
            session.requestDatabaseEditor(.alter)
            for _ in 0..<50 where session.databaseEditor?.catalog == nil {
                try? await Task.sleep(for: .milliseconds(20))
            }
        case .browser, .browserFiltered:
            session.view = .structure
            session.selectedObjectID = nil
        case .browserTabs:
            // S-037: order_items in the first tab, customers opened in a second.
            session.history.removeAll()
            show(.content, "table:order_items", in: session)
            await session.currentLoad?.value
            let before = Tabs.lastOpened
            session.openObjectInNewTab("table:customers")
            for _ in 0..<100 where Tabs.lastOpened == nil || Tabs.lastOpened === before {
                try? await Task.sleep(for: .milliseconds(20))
            }
            await Tabs.lastOpened?.waitForConnect()
        case .databaseInfo, .databaseHealth, .databaseCollations:
            session.view = .structure
            session.selectedObjectID = self == .databaseInfo ? "table:orders" : "table:notes"
            let tool: DatabaseInfo.Tool = switch self {
            case .databaseInfo: .check
            case .databaseHealth: .health
            default: .collations
            }
            await session.runTool(tool)?.value
        default:
            return nil
        }
        return false
    }
}
