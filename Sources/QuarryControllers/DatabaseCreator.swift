import Foundation
import Observation
import QuarryKit

/// The New Database sheet's state (S-018): a name, a character set and a
/// collation. `nil` for either means the default, the server's or the
/// character set's, so the statement leaves it out.
@Observable
package final class DatabaseCreator: Identifiable {
    package let id = UUID()
    private let existing: [String]

    package var name = ""
    /// Choosing another character set clears the collation, which belonged to the old one.
    package var charset: String? {
        didSet { if charset != oldValue { collation = nil } }
    }
    package var collation: String?

    package private(set) var catalog: CharsetCatalog?
    package private(set) var loadError: DatabaseError?
    package private(set) var createError: DatabaseError?
    package private(set) var isCreating = false

    package init(existing: [String]) {
        self.existing = existing
    }

    package func load(_ client: DatabaseClient) async {
        do {
            catalog = try await client.charsetCatalog()
        } catch {
            loadError = DatabaseError.from(error)
        }
    }

    /// Why the name cannot be used; nil for an empty name.
    package var nameProblem: String? { NewDatabase.problem(with: name, existing: existing) }

    package var canCreate: Bool { !name.isEmpty && nameProblem == nil && !isCreating }

    /// The collations the menu lists, for the chosen character set.
    package var collations: [String] { catalog?.collations(for: charset) ?? [] }

    /// "Server Default (utf8mb4)".
    package var defaultCharsetTitle: String {
        guard let catalog else { return "Server Default" }
        return "Server Default (\(catalog.serverCharset))"
    }

    /// "Server Default (utf8mb4_general_ci)" when the character set is the server's,
    /// "Default (latin1_swedish_ci)" when one was chosen.
    package var defaultCollationTitle: String {
        guard let catalog else { return "Default" }
        let name = catalog.defaultCollation(for: charset)
        let prefix = charset == nil ? "Server Default" : "Default"
        return name.isEmpty ? prefix : "\(prefix) (\(name))"
    }

    package var request: NewDatabase {
        NewDatabase(name: name, charset: charset, collation: collation)
    }

    /// Runs CREATE DATABASE. False, with the server's message, when it fails.
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
