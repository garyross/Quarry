import Foundation
import Observation
import QuarryKit

/// The Add Index sheet's state (S-024): the type, name, fields with their
/// prefixes, and the advanced options, as one ALTER TABLE … ADD.
@Observable
package final class IndexDraft: Identifiable {
    package let id = UUID()
    /// The table as it is: its name, engine and fields.
    package let shape: TableShape
    package var table: String { shape.table }
    /// The table's fields, for the field menus and the prefix rules.
    package var fields: [FieldDefinition] { shape.fields }
    /// The indexes the table has, for the name check.
    package let existing: [String]
    package let hasPrimaryKey: Bool
    /// The table's engine. A SQLite table (S-070): Index or Unique only, no prefixes or advanced options, and always a name.
    package var engine: Engine { shape.engine }
    package var isSQLite: Bool { engine == .sqlite }

    package var kind: IndexKind
    package var name = ""
    package var parts: [Part]
    package var storage = IndexStorage.default
    package var keyBlockSize = ""
    package var comment = ""
    package var showsAdvanced = false
    package var error: DatabaseError?
    package var isSaving = false

    package struct Part: Identifiable, Hashable {
        package let id = UUID()
        package var field: String
        package var prefix = ""

    package init(field: String, prefix: String = "") {
        self.field = field
        self.prefix = prefix
    }
    }

    /// Starts with `selected` fields (or the first), and Primary Key when the table has none.
    package init(shape: TableShape, indexes: [IndexSummary], selected: [String]) {
        self.shape = shape
        existing = indexes.map(\.name)
        hasPrimaryKey = indexes.contains(where: \.isPrimary)
        kind = hasPrimaryKey || shape.engine == .sqlite ? .index : .primary
        let start = selected.isEmpty ? Array(shape.fields.prefix(1).map(\.name)) : selected
        parts = start.map { Part(field: $0) }
    }

    package var title: String { "Add Index to \u{201C}\(table)\u{201D}" }

    /// The Type menu: SQLite makes a primary key only with the table.
    package var kinds: [IndexKind] { isSQLite ? [.index, .unique] : IndexKind.allCases }

    /// The name field: PRIMARY for a primary key, which can't change.
    package var shownName: String {
        get { kind == .primary ? "PRIMARY" : name }
        set { if kind != .primary { name = newValue } }
    }

    package func rule(for part: Part) -> PrefixRule {
        if isSQLite { return .none }
        return PrefixRule.of(type: fields.first { $0.name == part.field }?.type ?? "", kind: kind)
    }

    package func prefixPrompt(for part: Part) -> String {
        switch rule(for: part) {
        case .required: "Required"
        case .optional: "Optional"
        case .none: "None"
        }
    }

    /// + in the Fields section: the next field the index doesn't hold yet.
    package var canAddPart: Bool { parts.count < fields.count && !isSaving }

    package func addPart() {
        let used = Set(parts.map(\.field))
        guard let next = fields.first(where: { !used.contains($0.name) }) else { return }
        parts.append(Part(field: next.name))
    }

    package var canRemovePart: Bool { parts.count > 1 && !isSaving }

    package func removePart(_ id: Part.ID) {
        guard canRemovePart else { return }
        parts.removeAll { $0.id == id }
    }

    // MARK: Checks

    package var nameProblem: String? {
        kind == .primary ? nil : IndexChange.nameProblem(name, existing: existing)
    }

    private func prefixValue(_ part: Part) -> Int? {
        let text = part.prefix.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : Int(text)
    }

    private var partsAreValid: Bool {
        parts.allSatisfy { part in
            let text = part.prefix.trimmingCharacters(in: .whitespaces)
            switch rule(for: part) {
            case .none: return true
            case .optional: return text.isEmpty || (Int(text) ?? 0) > 0
            case .required: return (Int(text) ?? 0) > 0
            }
        }
    }

    private var keyBlockSizeIsValid: Bool {
        let text = keyBlockSize.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || (Int(text) ?? 0) > 0
    }

    package var canSave: Bool {
        !parts.isEmpty && nameProblem == nil && partsAreValid && keyBlockSizeIsValid && !isSaving
            && !(kind == .primary && hasPrimaryKey)
    }

    package var definition: IndexDefinition {
        IndexDefinition(kind: kind, name: name,
                        parts: parts.map { IndexPart(field: $0.field, prefix: rule(for: $0) == .none ? nil : prefixValue($0)) },
                        storage: storage, keyBlockSize: Int(keyBlockSize.trimmingCharacters(in: .whitespaces)),
                        comment: comment)
    }

    package var change: TableChange { .addIndex(definition) }

    /// What Add runs, shown under the form.
    package var sql: String { (try? change.plan(shape))?.summary ?? "" }

    /// The index's name once added: what the server will call it.
    package var landingName: String {
        if kind == .primary { return "PRIMARY" }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if isSQLite, trimmed.isEmpty { return ([table] + parts.map(\.field)).joined(separator: "_") }
        return trimmed.isEmpty ? parts.first?.field ?? "" : trimmed
    }
}
