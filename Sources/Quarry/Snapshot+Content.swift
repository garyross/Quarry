import AppKit
import QuarryKit
import SwiftUI

/// Snapshot pages for Content: rows, filters, editors and links.
extension SnapshotPage {
    /// nil: not one of these pages. true: ready now. false: ready once the session's load ends.
    @MainActor
    func prepareContent(_ session: Session, model: AppModel, local: SavedConnection?) async -> Bool? {
        switch self {
        case .content: show(.content, "table:customers", in: session)
        case .contentLarge: show(.content, "table:events", in: session)
        case .contentEditError:
            // A duplicate email: the server refuses it, so nothing changes.
            show(.content, "table:customers", in: session)
            await session.currentLoad?.value
            let email = session.content.grid.columns.firstIndex { $0.title == "email" } ?? 2
            session.editContent(row: 1, column: email, to: .text("ada@example.com"))
        case .contentContextMenu:
            // Two rows selected: the menu says "Delete 2 Rows…".
            show(.content, "table:customers", in: session)
            await session.currentLoad?.value
            session.content.editError = nil
            selectGridRows([1, 2])
        case .contentNewRow:
            // A new row with the table's defaults, its name cell editing.
            show(.content, "table:customers", in: session)
            await session.currentLoad?.value
            session.content.editError = nil
            session.addRow()
        case .contentFiltered, .contentNoMatch:
            // S-014: customers in the US, or a name nobody has.
            show(.content, "table:customers", in: session)
            await session.currentLoad?.value
            session.content.editError = nil
            session.content.filter.draft = FilterTree(self == .contentFiltered
                ? RowFilter(column: "country", op: .equals, value: "US")
                : RowFilter(column: "name", op: .contains, value: "Zuse"))
            session.applyFilter()
        case .contentRules:
            // S-015: All of (country = US, Any of (no email, name starts with "Mar")).
            show(.content, "table:customers", in: session)
            await session.currentLoad?.value
            session.content.editError = nil
            var tree = FilterTree(RowFilter(column: "country", value: "US"))
            let inner = tree.addGroup(RowFilter(column: "email", op: .isNull), below: tree.rules[0].id)
            tree.add(RowFilter(column: "name", op: .startsWith, value: "Mar"), below: inner)
            session.content.filter.draft = tree
            session.applyFilter()
        case .contentWhere, .contentWhereError:
            // S-061: a rule, then a WHERE clause typed as SQL; the error page has a typo in it.
            show(.content, "table:customers", in: session)
            await session.currentLoad?.value
            session.content.editError = nil
            var tree = FilterTree(RowFilter(column: "country", op: .notEquals, value: "US"))
            let clause = self == .contentWhere
                ? "id IN (SELECT customer_id FROM orders WHERE total > 50)"
                : "id IN (SELECT customer_id FROM orders WHERE totl > 50)"
            tree.add(RowFilter(column: "id", op: .sql, value: clause), below: tree.rules[0].id)
            session.content.filter.draft = tree
            session.applyFilter()
        case .fieldEditor, .fieldEditorHex, .fieldEditorImage:
            // S-012: a product's JSON attributes, an 8-byte BLOB, and a picture.
            show(.content, "table:products", in: session)
            await session.currentLoad?.value
            session.content.editError = nil
            let name = self == .fieldEditor ? "attributes" : "thumbnail"
            let column = session.content.grid.columns.firstIndex { $0.title == name } ?? 0
            session.openFieldEditor(row: self == .fieldEditorImage ? 4 : 0, column: column)
        case .bitEditor:
            // S-013: MUG-01's flags, b'00000101'.
            show(.content, "table:products", in: session)
            await session.currentLoad?.value
            session.content.editError = nil
            let column = session.content.grid.columns.firstIndex { $0.title == "flags" } ?? 0
            session.openFieldEditor(row: 0, column: column)
        case .contentLinks, .contentFollowed:
            // S-017: order_items with arrows in order_id and product_id, then the order one leads to.
            session.history.removeAll()
            show(.content, "table:order_items", in: session)
            await session.currentLoad?.value
            session.content.editError = nil
            if self == .contentFollowed {
                let column = session.content.grid.columns.firstIndex { $0.title == "order_id" } ?? 0
                await session.followLink(row: 2, column: column)?.value
            }
        default:
            return nil
        }
        return false
    }
}
