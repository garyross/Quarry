import Foundation
import Observation
import QuarryKit

/// The Duplicate Table sheet's state (S-022): a new name and whether the rows come too.
@Observable
package final class TableDuplicator: Identifiable {
    package let id = UUID()
    package let database: String
    package let source: String
    private let existing: [String]

    package var name: String
    package var withRows = true

    package private(set) var error: DatabaseError?
    package private(set) var isWorking = false

    package init(database: String, source: String, existing: [String]) {
        self.database = database
        self.source = source
        self.existing = existing
        name = TableEdit.copyName(for: source, existing: existing)
    }

    /// Why the name cannot be used; nil for an empty name.
    package var nameProblem: String? { NewTable.problem(with: name, existing: existing) }

    package var canRun: Bool { !name.isEmpty && nameProblem == nil && !isWorking }

    /// Copies the table. False, with the server's message, when it fails.
    package func run(_ client: DatabaseClient) async -> Bool {
        guard canRun else { return false }
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            try await client.duplicate(table: source, to: name, in: database, withRows: withRows)
            return true
        } catch {
            self.error = DatabaseError.from(error)
            return false
        }
    }
}

/// Empty Table… or Delete Table…, waiting on its alert (S-022).
package struct PendingTableEdit: Equatable {
    package enum Action { case empty, delete }

    package let action: Action
    package let objects: [DBObject]
    package var ignoreForeignKeys = false

    package init(action: Action, objects: [DBObject], ignoreForeignKeys: Bool = false) {
        self.action = action
        self.objects = objects
        self.ignoreForeignKeys = ignoreForeignKeys
    }

    /// "table", "view", "procedure", "function", or "items" for a mix.
    private var noun: String {
        let kinds = Set(objects.map(\.kind))
        guard kinds.count == 1, let kind = kinds.first else { return "items" }
        return CreateScript.noun(kind) + (objects.count == 1 ? "" : "s")
    }

    /// "Delete table “orders”?", "Empty 3 tables?".
    package var title: String {
        let verb = action == .empty ? "Empty" : "Delete"
        if objects.count == 1, let name = objects.first?.name { return "\(verb) \(noun) \u{201C}\(name)\u{201D}?" }
        return "\(verb) \(objects.count) \(noun)?"
    }

    package var message: String {
        let hasTables = objects.contains { $0.kind == .table }
        let effect = switch (action, objects.count == 1) {
        case (.empty, true): "Every row is deleted."
        case (.empty, false): "Every row in them is deleted."
        case (.delete, true): hasTables ? "Its rows, indexes and triggers are deleted."
            : "The \(CreateScript.noun(objects[0].kind))’s definition is deleted."
        case (.delete, false): hasTables ? "Tables go with their rows, indexes and triggers." : ""
        }
        let names = objects.count > 1 ? objects.map(\.name).joined(separator: ", ") + ". " : ""
        return names + effect + (effect.isEmpty ? "" : " ") + "This can't be undone."
    }

    package var buttonTitle: String { action == .empty ? "Empty" : "Delete" }
}
