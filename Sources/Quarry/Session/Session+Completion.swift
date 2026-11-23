import Foundation
import QuarryKit

/// Completions in the query editor (S-031). The catalog holds each database's
/// tables and columns, read once from information_schema and read again when
/// Query opens or a statement may have changed the schema.
extension Session {
    /// The list at `cursor`, or nil. Asks for a database's tables when the
    /// position needs them; the editor refreshes when they arrive.
    func completions(_ text: String, cursor: Int, explicit: Bool) -> CompletionList? {
        let catalog = CompletionCatalog(databases: databases, currentDatabase: database, tables: completionTables)
        let list = SQLCompletion.complete(text, cursor: cursor, catalog: catalog, explicit: explicit)
        if let needed = list?.needsDatabase { loadCompletionTables(needed) }
        guard let list, !list.items.isEmpty else { return nil }
        return list
    }

    /// Forgets the cached tables and reads the current database's again.
    func refreshCompletionCatalog() {
        completionTables = [:]
        if let database { loadCompletionTables(database) }
    }

    @discardableResult
    func loadCompletionTables(_ name: String) -> Task<Void, Never>? {
        guard let client, phase == .connected, completionTables[name] == nil,
              !loadingCompletionDatabases.contains(name) else { return nil }
        loadingCompletionDatabases.insert(name)
        return Task {
            let tables = (try? await client.completionTables(in: name)) ?? []
            loadingCompletionDatabases.remove(name)
            completionTables[name] = tables
            query.completionRevision += 1
        }
    }
}
