import Foundation
import Observation
import QuarryKit

/// The Add Field and Edit Field sheet's state (S-023): one field's definition
/// and where it goes. Choosing another type clears the options it can't have.
@Observable
package final class FieldDraft: Identifiable {
    package let id = UUID()
    /// The table as it is: its name, engine, fields and, on SQLite, its CREATE TABLE (S-070).
    package let shape: TableShape
    package var table: String { shape.table }
    /// The field's name before editing; nil when adding.
    package let original: String?
    package let originalPosition: FieldPosition
    /// The table's fields in order, for the Position menu and the name check.
    package let names: [String]

    package var name: String
    package private(set) var field: FieldDefinition
    package var position: FieldPosition
    package var defaultKind: DefaultKind
    package var defaultText: String
    package var catalog: CharsetCatalog? {
        didSet {
            // The server prints only the collation; its character set fills the menu.
            if charset == nil, let collation = field.collation, let catalog {
                field.charset = catalog.charsets.first { catalog.collations(for: $0.name).contains(collation) }?.name
            }
        }
    }
    package var error: DatabaseError?
    package var isSaving = false
    package var isSQLite: Bool { shape.engine == .sqlite }
    /// A STRICT table takes only its own types.
    package var isStrict: Bool { shape.sqlite?.isStrict == true }

    package enum DefaultKind: Hashable {
        case none, null, currentTimestamp, value

        package var title: String {
            switch self {
            case .none: "No Default"
            case .null: "NULL"
            case .currentTimestamp: "CURRENT_TIMESTAMP"
            case .value: "Value"
            }
        }
    }

    package init(shape: TableShape, field: FieldDefinition, original: String?, names: [String], position: FieldPosition) {
        self.shape = shape
        self.field = field
        self.original = original
        self.names = names
        self.position = position
        originalPosition = position
        name = field.name
        (defaultKind, defaultText) = Self.split(field.defaultValue)
    }

    private static func split(_ value: FieldDefault) -> (DefaultKind, String) {
        switch value {
        case .none: (.none, "")
        case .null: (.null, "")
        case .value(let text): (.value, text)
        case .expression(let text):
            FieldDefault.isExpression(text) && !text.lowercased().hasPrefix("b'") && !text.lowercased().hasPrefix("x'")
                ? (.currentTimestamp, "") : (.value, text)
        }
    }

    package var isAdding: Bool { original == nil }
    package var title: String { isAdding ? "Add Field to \u{201C}\(table)\u{201D}" : "Edit Field \u{201C}\(original ?? "")\u{201D}" }

    // MARK: The menus

    package var type: String {
        get { field.type }
        set {
            if isSQLite {
                // Any name is a SQLite type; only an INTEGER key can AUTOINCREMENT.
                field.type = newValue.lowercased()
                if field.type != "integer" { field.extra = .none }
                return
            }
            field = field.changingType(to: newValue)
            (defaultKind, defaultText) = Self.split(field.defaultValue)
        }
    }

    package var length: String {
        get { field.length }
        set { field.length = newValue }
    }

    package var isUnsigned: Bool {
        get { field.isUnsigned }
        set { field.isUnsigned = newValue }
    }

    package var isZerofill: Bool {
        get { field.isZerofill }
        set { field.isZerofill = newValue }
    }

    package var isNullable: Bool {
        get { field.isNullable }
        set {
            field.isNullable = newValue
            if !newValue, defaultKind == .null { defaultKind = .none }
        }
    }

    package var extra: FieldExtra {
        get { field.extra }
        set { field.extra = newValue }
    }

    package var charset: String? {
        get { field.charset }
        set {
            guard newValue != field.charset else { return }
            field.charset = newValue
            field.collation = nil
        }
    }

    package var collation: String? {
        get { field.collation }
        set { field.collation = newValue }
    }

    package var comment: String {
        get { field.comment }
        set { field.comment = newValue }
    }

    package var family: TypeFamily { field.family }
    package var takesLength: Bool { FieldDefinition.takesLength(field.type) }
    package var collations: [String] { catalog?.collations(for: charset) ?? [] }

    /// The types menu: the family lists, with a type the menu doesn't know (uuid) first.
    package var extraType: String? { field.family == .other ? field.type : nil }

    package var defaultKinds: [DefaultKind] {
        // SQLite takes any default on any type.
        if isSQLite { return field.isNullable ? [.none, .null, .currentTimestamp, .value] : [.none, .currentTimestamp, .value] }
        var kinds: [DefaultKind] = [.none]
        if field.isNullable { kinds.append(.null) }
        if family == .time { kinds.append(.currentTimestamp) }
        if ![.text, .blob, .json, .spatial].contains(family) { kinds.append(.value) }
        if !kinds.contains(defaultKind) { kinds.append(defaultKind) }
        return kinds
    }

    package var extras: [FieldExtra] {
        if isSQLite { return isRowIDKey || field.extra == .autoIncrement ? [.none, .autoIncrement] : [.none] }
        return FieldExtra.allCases.filter { $0.applies(to: field.type) || $0 == field.extra }
    }

    /// AUTOINCREMENT needs the table's one primary key field, typed INTEGER.
    private var isRowIDKey: Bool {
        guard let create = shape.sqlite, let original, field.type == "integer", let column = create.column(named: original) else { return false }
        let keyed = create.columns.filter(\.isPrimaryKey).count
        let tableKey = create.constraints.first { $0.kind == "PRIMARY" }.map { $0.keyColumns }
        return (create.columns[column].isPrimaryKey && keyed == 1 && tableKey == nil)
            || (keyed == 0 && tableKey == [original.lowercased()])
    }

    /// The SQLite types menu: SQLite's names, or a STRICT table's.
    package var sqliteTypes: [String] { SQLiteTableChange.types(strict: isStrict) }

    package func extraTitle(_ extra: FieldExtra) -> String { isSQLite && extra == .autoIncrement ? "AUTOINCREMENT" : extra.title }

    /// "First", or after each other field.
    package var positions: [FieldPosition] {
        [.first] + names.filter { $0 != original }.map(FieldPosition.after)
    }

    package var lengthPrompt: String {
        switch family {
        case .integer: "Display width"
        case .decimal: "10,2"
        case .bit: "1–64"
        case .string, .binary: field.type.hasPrefix("var") ? "Required" : "1"
        case .list: "'a','b'"
        case .time, .date: "Fractional seconds"
        default: ""
        }
    }

    // MARK: Saving

    package var nameProblem: String? {
        if name.isEmpty { return nil }
        if name.count > 64 { return "A field name can be at most 64 characters." }
        if name.last?.isWhitespace == true { return "A field name can’t end with a space." }
        if names.contains(where: { $0 != original && $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return "The table already has a field named “\(name)”."
        }
        return nil
    }

    package var canSave: Bool { !name.isEmpty && nameProblem == nil && !isSaving && !field.type.isEmpty }

    /// The field as the statement makes it.
    package var definition: FieldDefinition {
        var result = field
        result.name = name
        switch defaultKind {
        case .none: result.defaultValue = .none
        case .null: result.defaultValue = .null
        case .currentTimestamp where isSQLite:
            result.defaultValue = .expression("CURRENT_TIMESTAMP")
        case .value where isSQLite:
            result.defaultValue = SQLiteTableChange.isExpression(defaultText) ? .expression(defaultText) : .value(defaultText)
        case .currentTimestamp:
            let precision = Int(field.length) != nil ? "(\(field.length))" : ""
            result.defaultValue = .expression("CURRENT_TIMESTAMP" + precision)
        case .value:
            result.defaultValue = FieldDefault.isExpression(defaultText) ? .expression(defaultText) : .value(defaultText)
        }
        return result
    }

    /// The change Save makes: an edit (with its move) or an add.
    package var change: TableChange {
        if let original { return .editField(original, definition, position == originalPosition ? .unchanged : position) }
        return .addField(definition, position)
    }

    /// What Save runs, shown under the form: the ALTER TABLE, or SQLite's rebuild.
    package var sql: String { (try? change.plan(shape))?.summary ?? "" }
}

extension FieldPosition {
    package var title: String {
        switch self {
        case .unchanged: "Where It Is"
        case .first: "First"
        case .after(let name): "After \(name)"
        }
    }
}
