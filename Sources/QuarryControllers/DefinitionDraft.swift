import Foundation
import Observation
import QuarryKit

/// The New View, New Procedure and New Function sheet, and its Edit twin
/// (S-030): a name, the object's options, and its SELECT or body. Saving a
/// routine edit drops it and creates it again; the original comes back when
/// the create fails.
@Observable
package final class DefinitionDraft: Identifiable {
    package let id = UUID()
    package let database: String
    package let kind: ObjectKind
    /// The object being edited; nil makes a new one.
    package let originalName: String?
    /// Every object in the database, for the name check.
    package let existing: [DBObject]

    package var name = ""
    // View
    package var algorithm: ViewAlgorithm = .undefined
    package var checkOption: ViewCheckOption = .none
    // Routine
    package var parameters = ""
    package var returns = ""
    package var deterministic = false
    package var dataAccess: RoutineDataAccess = .containsSQL
    package var comment = ""
    // Both
    package var security: SQLSecurity = .definer
    /// The view's SELECT, or the routine's body.
    package var text = ""

    package private(set) var originalView: ViewDefinition?
    package private(set) var originalRoutine: RoutineDefinition?
    package private(set) var originalStatement: String?
    package var error: DatabaseError?
    package var isLoading = false
    package var isSaving = false

    /// A SQLite file's view (S-070): no algorithm, security or check option.
    package let engine: Engine
    package var isSQLite: Bool { engine == .sqlite }

    package init(database: String, kind: ObjectKind, editing name: String? = nil, existing: [DBObject], engine: Engine) {
        self.database = database
        self.engine = engine
        self.kind = kind
        originalName = name
        self.existing = existing
        self.name = name ?? ""
        switch kind {
        case .view: text = "SELECT "
        case .procedure: text = "BEGIN\n  \nEND"
        case .function:
            returns = "INT"
            text = "BEGIN\n  RETURN 0;\nEND"
        case .table: break
        }
        isLoading = name != nil
    }

    package var isEdit: Bool { originalName != nil }
    package var isRoutine: Bool { kind == .procedure || kind == .function }
    package var noun: String { CreateScript.noun(kind) }

    package var title: String {
        if let originalName { return "Edit \(noun.capitalized) \u{201C}\(originalName)\u{201D}" }
        return "New \(noun.capitalized) in \u{201C}\(database)\u{201D}"
    }

    package var saveTitle: String { isEdit ? "Save" : "Create" }

    /// Reads the definition being edited.
    package func load(_ client: DatabaseClient) async {
        guard let originalName else { return }
        defer { isLoading = false }
        do {
            if kind == .view {
                let view = try await client.viewDefinition(originalName, in: database)
                originalView = view
                algorithm = view.algorithm
                security = view.security
                checkOption = view.checkOption
                text = view.select
            } else {
                let (routine, statement) = try await client.routineDefinition(DBObject(name: originalName, kind: kind),
                                                                              in: database)
                originalRoutine = routine
                originalStatement = statement
                parameters = routine.parameters
                returns = routine.returns
                deterministic = routine.deterministic
                dataAccess = routine.dataAccess
                security = routine.security
                comment = routine.comment
                text = routine.body
            }
        } catch {
            self.error = DatabaseError.from(error)
        }
    }

    private var trimmedName: String { name }

    package var view: ViewDefinition {
        ViewDefinition(name: trimmedName, algorithm: algorithm, security: security, checkOption: checkOption, select: text)
    }

    package var routine: RoutineDefinition {
        RoutineDefinition(kind: kind, name: trimmedName, parameters: parameters, returns: returns, deterministic: deterministic,
                          dataAccess: dataAccess, security: security, comment: comment, body: text)
    }

    package var plan: DefinitionChange.Plan {
        kind == .view
            ? DefinitionChange.plan(view, replacing: originalView, in: database, engine: engine)
            : DefinitionChange.plan(routine, replacing: originalRoutine, originalStatement: originalStatement, in: database)
    }

    /// The statement Create or Save runs, shown in the sheet's footer.
    package var statement: String { plan.create }

    package var nameProblem: String? {
        DefinitionChange.nameProblem(name, kind: kind, existing: existing, original: originalName)
    }

    private var isChanged: Bool {
        if kind == .view { return originalView.map { $0 != view } ?? true }
        return originalRoutine.map { $0 != routine } ?? true
    }

    private var isLoaded: Bool { !isEdit || originalView != nil || originalRoutine != nil }

    package var canSave: Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasBody = kind == .view ? body.count > "SELECT".count || !body.uppercased().hasPrefix("SELECT") : !body.isEmpty
        let hasReturns = kind != .function || !returns.trimmingCharacters(in: .whitespaces).isEmpty
        return !name.isEmpty && nameProblem == nil && hasBody && hasReturns && isLoaded && isChanged && !isSaving && !isLoading
    }

    /// Runs the plan. False, with the server's message, when it fails.
    package func save(_ client: DatabaseClient) async -> Bool {
        guard canSave else { return false }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            try await Self.apply(plan, noun: noun, client: client)
            return true
        } catch {
            self.error = DatabaseError.from(error)
            return false
        }
    }

    /// Drop, create, then the cleanup; on a failed create, the first restore that works.
    package static func apply(_ plan: DefinitionChange.Plan, noun: String, client: DatabaseClient) async throws {
        if let drop = plan.drop { _ = try await client.run(drop) }
        do {
            _ = try await client.run(plan.create)
        } catch {
            guard !plan.restore.isEmpty else { throw error }
            var failure = DatabaseError.from(error)
            var restoreError: DatabaseError?
            for statement in plan.restore {
                do {
                    _ = try await client.run(statement)
                    restoreError = nil
                    break
                } catch {
                    restoreError = DatabaseError.from(error)
                }
            }
            failure.suggestion = restoreError.map { "The original \(noun) couldn\u{2019}t be put back: " + $0.message }
                ?? "The \(noun) wasn\u{2019}t changed."
            throw failure
        }
        if let cleanup = plan.cleanup { _ = try await client.run(cleanup) }
    }
}
