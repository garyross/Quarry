import AppKit
import QuarryKit
import SwiftUI

/// Snapshot pages for Query, completions, history, saved queries and the Console.
extension SnapshotPage {
    /// nil: not one of these pages. true: ready now. false: ready once the session's load ends.
    @MainActor
    func prepareQuery(_ session: Session, model: AppModel, local: SavedConnection?) async -> Bool? {
        switch self {
        case .query:
            session.view = .query
            session.query.text = """
            SELECT c.name, c.country, COUNT(o.id) AS orders, SUM(o.total) AS spent
            FROM customers c
            LEFT JOIN orders o ON o.customer_id = c.id
            GROUP BY c.id
            ORDER BY spent DESC;

            -- Products that never sold
            SELECT * FROM products WHERE id NOT IN (SELECT product_id FROM order_items);
            """
            session.query.cursor = 0
            session.runCurrentStatement()
        case .queryCompletion:
            // S-031: the list open after "SELECT * FROM ord".
            session.view = .query
            session.query.text = "SELECT * FROM ord"
            session.query.cursor = 17
            session.query.results = .empty
            session.query.status = ""
            if let database = session.database {
                await session.loadCompletionTables(database)?.value
            }
            try? await Task.sleep(for: .milliseconds(200))
            session.query.selectRequest = NSRange(location: 17, length: 0)
            session.query.completionRequest = true
            try? await Task.sleep(for: .milliseconds(300))
            return true
        case .queryHistoryMenu:
            // S-033: the run bar's History popover over a few past queries.
            session.view = .query
            session.query.text = "SELECT * FROM customers WHERE country = 'GB';"
            session.query.cursor = 0
            session.query.results = .empty
            session.query.status = ""
            if let key = session.historyKey {
                model.clearHistory(for: key)
                for text in ["SHOW TABLES", "SELECT COUNT(*) FROM events",
                             "SELECT c.name, SUM(o.total) AS spent\nFROM customers c\nJOIN orders o ON o.customer_id = c.id\nGROUP BY c.id\nORDER BY spent DESC",
                             "UPDATE products SET price = price * 1.05 WHERE category = 'Books'",
                             "SELECT * FROM orders WHERE status = 'shipped' ORDER BY placed_at DESC LIMIT 50"] {
                    model.addHistory(text, serverKey: key, database: session.database)
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            session.query.showsHistory = true
            return true
        case .console:
            // S-039: a few statements, one with an error, as browsing and Query send them.
            Console.shared.clear()
            session.view = .query
            session.query.text = "SELECT c.name, SUM(o.total) AS spent\nFROM customers c\nJOIN orders o ON o.customer_id = c.id\nGROUP BY c.id;\n"
                + "UPDATE products SET price = price * 1.05 WHERE id = 0;\nSELEC oops;"
            session.runAll()
            await session.currentLoad?.value
            try? await Task.sleep(for: .milliseconds(300))
            return true
        case .queryFavoritesMenu, .queryFavoriteManager:
            // S-034: a few saved queries, the popover over the run bar or the window on its own.
            session.view = .query
            session.query.text = "SELECT * FROM customers WHERE country = 'GB';"
            session.query.cursor = 0
            session.query.results = .empty
            session.query.status = ""
            seedSavedQueries(model)
            try? await Task.sleep(for: .milliseconds(300))
            if self == .queryFavoritesMenu { session.query.showsSavedQueries = true }
            return true
        case .saveQuery:
            // S-034: two statements, so the sheet offers Current Statement or Whole Editor.
            session.view = .query
            session.query.text = "SELECT c.name, SUM(o.total) AS spent\nFROM customers c\nJOIN orders o ON o.customer_id = c.id\nGROUP BY c.id\nORDER BY spent DESC;\n\nSHOW TABLES;"
            session.query.cursor = 0
            session.query.selection = NSRange(location: 0, length: 0)
            seedSavedQueries(model)
            try? await Task.sleep(for: .milliseconds(300))
            session.beginSaveQuery()
            return true
        case .queryRunning:
            // S-036: captured while SLEEP runs, with Cancel showing; it ends on its own soon after.
            session.view = .query
            session.query.text = "SELECT SLEEP(3);"
            session.query.cursor = 0
            session.runCurrentStatement()
            try? await Task.sleep(for: .seconds(0.5))
            return true
        case .queryError:
            session.view = .query
            session.query.text = "SELECT name, email\nFROM customers\nWHER country = 'GB';"
            session.query.cursor = 0
            session.runAll()
        default:
            return nil
        }
        return false
    }
}
