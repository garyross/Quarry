import Foundation
import Observation
import QuarryKit

/// The Add Foreign Key sheet's state (S-025): the field, the table and field it
/// references, the actions, and the name, as one ALTER TABLE … ADD FOREIGN KEY.
@Observable
package final class ForeignKeyDraft: Identifiable {
    package let id = UUID()
    /// The table as it was when the sheet opened: name, engine, keys and, on SQLite, its CREATE TABLE.
    package let shape: TableShape
    package var table: String { shape.table }
    /// The table's fields that can be in a key.
    package let fields: [FieldDefinition]
    /// The database's InnoDB tables, by name.
    package let tables: [String]
    /// The table's foreign keys, for the name check.
    package let existing: [String]

    package var name = ""
    package var field: String {
        didSet { if field != oldValue { fieldChanged() } }
    }
    package var referencedTable: String
    package var referencedField = ""
    package var onUpdate = ForeignKeyAction.restrict
    package var onDelete = ForeignKeyAction.restrict
    package var error: DatabaseError?
    package var isSaving = false
    /// The referenced table's fields and indexes, once loaded.
    package private(set) var catalog: [String: Reference] = [:]
    package var isLoadingReference: Bool { catalog[referencedTable] == nil }

    package struct Reference {
        package let fields: [FieldDefinition]
        package let indexes: [IndexSummary]
        /// The unique indexes (PRIMARY included), which SQLite's parent keys need.
        package var unique: Set<String> = []

    package init(fields: [FieldDefinition], indexes: [IndexSummary], unique: Set<String> = []) {
        self.fields = fields
        self.indexes = indexes
        self.unique = unique
    }
    }

    /// The table's engine. A SQLite table (S-070): any type matches, and the referenced field is a primary key or a unique field.
    package var engine: Engine { shape.engine }
    package var isSQLite: Bool { engine == .sqlite }

    /// Starts on the first `_id` field no key uses yet, and the table its name points at.
    package init(shape: TableShape, fields: [FieldDefinition], keyed: Set<String>, tables: [String], existing: [String]) {
        self.shape = shape
        self.fields = shape.engine == .sqlite ? fields.filter { !$0.isGenerated } : fields.filter(ForeignKeyChange.canBeKeyed)
        self.tables = tables
        self.existing = existing
        let free = self.fields.filter { !keyed.contains($0.name) }
        let start = free.first { $0.name.lowercased().hasSuffix("_id") } ?? free.first ?? self.fields.first
        let startName = start?.name ?? ""
        field = startName
        let others = tables.filter { $0 != shape.table }
        referencedTable = ForeignKeyChange.guessTable(for: startName, among: tables) ?? others.first ?? tables.first ?? ""
    }

    package var title: String { "Add Foreign Key to \u{201C}\(table)\u{201D}" }

    package var fieldDefinition: FieldDefinition? { fields.first { $0.name == field } }

    /// The referenced table's fields this field can point at.
    package var candidates: [String] {
        guard let definition = fieldDefinition, let reference = catalog[referencedTable] else { return [] }
        if isSQLite {
            let parents = Set(reference.indexes.filter { reference.unique.contains($0.name) && $0.fields.count == 1 }.compactMap(\.fields.first))
            return reference.fields.filter { parents.contains($0.name) }.map(\.name)
        }
        return ForeignKeyChange.referenceable(from: definition, among: reference.fields, indexes: reference.indexes)
    }

    /// The referenced table loaded: keep the chosen field if it fits, else the first one that does.
    package func store(_ reference: Reference, for table: String) {
        catalog[table] = reference
        if table == referencedTable { pickReferencedField() }
    }

    package func referencedTableChanged() { pickReferencedField() }

    private func fieldChanged() {
        if !nullAllowed {
            if onUpdate == .setNull { onUpdate = .restrict }
            if onDelete == .setNull { onDelete = .restrict }
        }
        pickReferencedField()
    }

    private func pickReferencedField() {
        let options = candidates
        if !options.contains(referencedField) { referencedField = options.first ?? "" }
    }

    /// Set NULL needs a field that allows NULL.
    package var nullAllowed: Bool { fieldDefinition?.isNullable ?? false }

    /// Under Referenced Field when nothing fits.
    package var referenceProblem: String? {
        guard !isLoadingReference, candidates.isEmpty, let definition = fieldDefinition else { return nil }
        if isSQLite { return "\u{201C}\(referencedTable)\u{201D} has no primary key or unique field to point at." }
        let type = (definition.type + (definition.family == .decimal && !definition.length.isEmpty ? "(\(definition.length))" : "")
                    + (definition.isUnsigned ? " unsigned" : "")).uppercased()
        return "No field in \u{201C}\(referencedTable)\u{201D} matches \(field)\u{2019}s type, \(type), and leads an index."
    }

    package var nameProblem: String? { ForeignKeyChange.nameProblem(name, existing: existing) }

    package var canSave: Bool {
        !field.isEmpty && !referencedTable.isEmpty && candidates.contains(referencedField) && nameProblem == nil
            && !isSaving && (nullAllowed || (onUpdate != .setNull && onDelete != .setNull))
    }

    package var definition: ForeignKeyDefinition {
        ForeignKeyDefinition(name: name, field: field, referencedTable: referencedTable, referencedField: referencedField,
                             onUpdate: onUpdate, onDelete: onDelete)
    }

    package var change: TableChange { .addForeignKey(definition) }

    /// What Add runs, shown under the form: the ALTER TABLE, or SQLite's rebuild.
    package var sql: String { (try? change.plan(shape))?.summary ?? "" }
}
