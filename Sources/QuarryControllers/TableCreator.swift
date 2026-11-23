import Foundation
import Observation
import QuarryKit

/// The New Table sheet's state (S-021): a name, an engine, a character set
/// and a collation. `nil` for a menu means the database's default, so the
/// statement leaves it out.
@Observable
package final class TableCreator: Identifiable {
    package let id = UUID()
    package let database: String
    private let existing: [String]

    package var name = ""
    package var engine: String?
    /// Choosing another character set clears the collation, which belonged to the old one.
    package var charset: String? {
        didSet { if charset != oldValue { collation = nil } }
    }
    package var collation: String?

    package private(set) var catalog: CharsetCatalog?
    package private(set) var defaults: TableDefaults?
    package private(set) var loadError: DatabaseError?
    package private(set) var createError: DatabaseError?
    package private(set) var isCreating = false

    /// The connection's kind. A SQLite file (S-070): no storage engine or character set to choose.
    package let connectionEngine: Engine
    package var isSQLite: Bool { connectionEngine == .sqlite }

    package init(database: String, existing: [String], engine: Engine) {
        self.database = database
        self.existing = existing
        connectionEngine = engine
    }

    package func load(_ client: DatabaseClient) async {
        guard !isSQLite else { return }
        do {
            defaults = try await client.tableDefaults(in: database)
            catalog = try await client.charsetCatalog()
        } catch {
            loadError = DatabaseError.from(error)
        }
    }

    package var isLoading: Bool { !isSQLite && catalog == nil && loadError == nil }

    /// Why the name cannot be used; nil for an empty name.
    package var nameProblem: String? { NewTable.problem(with: name, existing: existing) }

    package var canCreate: Bool { !name.isEmpty && nameProblem == nil && !isCreating && !isLoading }

    /// The collations the menu lists: the chosen character set's, or the database's.
    package var collations: [String] { catalog?.collations(for: charset ?? defaults?.charset) ?? [] }

    /// "Default (InnoDB)".
    package var defaultEngineTitle: String {
        guard let engine = defaults?.defaultEngine, !engine.isEmpty else { return "Default" }
        return "Default (\(engine))"
    }

    /// "Database Default (utf8mb4)".
    package var defaultCharsetTitle: String {
        guard let charset = defaults?.charset, !charset.isEmpty else { return "Database Default" }
        return "Database Default (\(charset))"
    }

    /// "Database Default (utf8mb4_general_ci)" when the character set is the database's,
    /// "Default (latin1_swedish_ci)" when one was chosen.
    package var defaultCollationTitle: String {
        let name = charset == nil ? defaults?.collation ?? "" : catalog?.defaultCollation(for: charset) ?? ""
        let prefix = charset == nil ? "Database Default" : "Default"
        return name.isEmpty ? prefix : "\(prefix) (\(name))"
    }

    package var request: NewTable {
        NewTable(name: name, engine: engine, charset: charset, collation: collation)
    }

    /// Runs CREATE TABLE. False, with the server's message, when it fails.
    package func create(_ client: DatabaseClient) async -> Bool {
        guard canCreate else { return false }
        isCreating = true
        defer { isCreating = false }
        createError = nil
        do {
            try await client.create(request)
            return true
        } catch {
            createError = DatabaseError.from(error)
            return false
        }
    }
}
