import Foundation

/// What kind of value a field type holds, which decides the options it takes (S-023).
public enum TypeFamily: String, Sendable, CaseIterable {
    case integer, decimal, bit, string, binary, text, blob, list, date, time, json, spatial, other

    public var title: String {
        switch self {
        case .integer: "Integer"
        case .decimal: "Decimal and Floating Point"
        case .bit: "Bit"
        case .string: "String"
        case .binary: "Binary"
        case .text: "Text"
        case .blob: "Blob"
        case .list: "Enum and Set"
        case .date: "Date"
        case .time: "Date and Time"
        case .json: "JSON"
        case .spatial: "Spatial"
        case .other: "Other"
        }
    }

    /// The types the type menu lists, by family, in Sequel Pro's order.
    public var types: [String] {
        switch self {
        case .integer: ["tinyint", "smallint", "mediumint", "int", "bigint"]
        case .decimal: ["decimal", "float", "double"]
        case .bit: ["bit"]
        case .string: ["char", "varchar"]
        case .binary: ["binary", "varbinary"]
        case .text: ["tinytext", "text", "mediumtext", "longtext"]
        case .blob: ["tinyblob", "blob", "mediumblob", "longblob"]
        case .list: ["enum", "set"]
        case .date: ["date", "year"]
        case .time: ["datetime", "timestamp", "time"]
        case .json: ["json"]
        case .spatial: ["geometry", "point", "linestring", "polygon", "multipoint", "multilinestring",
                        "multipolygon", "geometrycollection"]
        case .other: []
        }
    }

    /// The family of a base type such as "varchar"; `.other` for one the menu doesn't list (uuid, inet6).
    public init(type: String) {
        let lower = type.lowercased()
        let aliases = ["integer": "int", "dec": "decimal", "numeric": "decimal", "fixed": "decimal", "real": "double",
                       "bool": "tinyint", "boolean": "tinyint"]
        let base = aliases[lower] ?? lower
        self = TypeFamily.allCases.first { $0.types.contains(base) } ?? .other
    }

    public var isNumeric: Bool { self == .integer || self == .decimal }
    /// Text and enum values have a character set and collation; binary strings and blobs don't.
    public var hasCollation: Bool { self == .string || self == .text || self == .list }
}

/// A field's default: none, NULL, a quoted value, or an expression such as CURRENT_TIMESTAMP.
public enum FieldDefault: Sendable, Hashable {
    case none, null, value(String), expression(String)

    /// From what people type: empty is no default, CURRENT_TIMESTAMP, NOW() and b'0101' are expressions.
    public init(typed text: String) {
        if text.isEmpty { self = .none }
        else if FieldDefault.isExpression(text) { self = .expression(text) }
        else { self = .value(text) }
    }

    /// The text the grid and the inline editor show ("" for none; NULL draws as NULL).
    public var text: String {
        switch self {
        case .none, .null: ""
        case .value(let value), .expression(let value): value
        }
    }

    /// current_timestamp(), CURRENT_TIMESTAMP(3), now() (not a bare "now"), localtimestamp, a b'…' bit literal, or x'…' hex.
    public static func isExpression(_ text: String) -> Bool {
        let pattern = #"^(?i)((current_timestamp|localtime|localtimestamp)(\(\d*\))?|now\(\d*\)|[bx]'[0-9a-f]*'|curdate\(\)|current_date(\(\))?)$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    var isTimestamp: Bool {
        if case .expression(let text) = self { return !text.lowercased().hasPrefix("b'") && !text.lowercased().hasPrefix("x'") }
        return false
    }
}

/// What a field does after its default: nothing, AUTO_INCREMENT, or ON UPDATE CURRENT_TIMESTAMP.
public enum FieldExtra: String, Sendable, CaseIterable {
    case none, autoIncrement, onUpdate

    public var title: String {
        switch self {
        case .none: "None"
        case .autoIncrement: "auto_increment"
        case .onUpdate: "on update CURRENT_TIMESTAMP"
        }
    }

    /// Whether a type family can have it: AUTO_INCREMENT on integers, ON UPDATE on DATETIME and TIMESTAMP.
    public func applies(to type: String) -> Bool {
        switch self {
        case .none: true
        case .autoIncrement: TypeFamily(type: type) == .integer
        case .onUpdate: ["datetime", "timestamp"].contains(type.lowercased())
        }
    }
}

/// A field as Structure edits it, and the column definition ALTER TABLE takes (S-023):
/// `name` TYPE(length) UNSIGNED ZEROFILL CHARACTER SET … COLLATE … NOT NULL DEFAULT … AUTO_INCREMENT COMMENT '…'
public struct FieldDefinition: Sendable, Hashable {
    public var name: String
    /// The base type, lowercase: "varchar".
    public var type: String
    /// What goes in the parentheses: "255", "10,2", "'a','b'"; empty for none.
    public var length: String
    public var isUnsigned: Bool
    public var isZerofill: Bool
    public var isNullable: Bool
    public var defaultValue: FieldDefault
    public var extra: FieldExtra
    /// The fractional seconds of ON UPDATE CURRENT_TIMESTAMP(3), as the server printed it.
    public var onUpdatePrecision: String
    /// nil keeps the table's default.
    public var charset: String?
    public var collation: String?
    public var comment: String
    /// MariaDB's INVISIBLE: kept as it was.
    public var isInvisible: Bool
    /// A generated (virtual or stored) field: the expression isn't in SHOW COLUMNS, so Structure doesn't change it.
    public internal(set) var isGenerated: Bool

    public init(name: String, type: String, length: String = "", isUnsigned: Bool = false, isZerofill: Bool = false,
                isNullable: Bool = true, defaultValue: FieldDefault = .none, extra: FieldExtra = .none,
                charset: String? = nil, collation: String? = nil, comment: String = "") {
        self.name = name
        self.type = type.lowercased()
        self.length = length
        self.isUnsigned = isUnsigned
        self.isZerofill = isZerofill
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.extra = extra
        onUpdatePrecision = ""
        self.charset = charset
        self.collation = collation
        self.comment = comment
        isInvisible = false
        isGenerated = false
    }

    /// From SHOW FULL COLUMNS. A missing default is NULL on a nullable field and none on a NOT NULL one.
    public init(_ field: FieldInfo) {
        self.init(name: field.name, type: field.baseType, length: field.length, isUnsigned: field.isUnsigned,
                  isZerofill: field.isZerofill, isNullable: field.isNullable, collation: field.collation,
                  comment: field.comment)
        let extra = field.extra.lowercased()
        isGenerated = extra.contains("generated") && !extra.contains("default_generated")
        isInvisible = extra.contains("invisible")
        if extra.contains("auto_increment") {
            self.extra = .autoIncrement
        } else if let range = extra.range(of: #"on update (current_timestamp|now)(\((\d*)\))?"#, options: .regularExpression) {
            self.extra = .onUpdate
            onUpdatePrecision = String(extra[range]).filter(\.isNumber)
        }
        if let value = field.defaultValue {
            // MySQL 8 marks expression defaults DEFAULT_GENERATED; MariaDB prints them unquoted.
            let expression = extra.contains("default_generated") || FieldDefault.isExpression(value)
            defaultValue = expression ? .expression(value) : .value(value)
        } else {
            defaultValue = field.isNullable ? .null : .none
        }
    }

    public var family: TypeFamily { TypeFamily(type: type) }

    /// Whether this type takes a length: every family but text, blob, JSON, spatial and DATE.
    public static func takesLength(_ type: String) -> Bool {
        switch TypeFamily(type: type) {
        case .text, .blob, .json, .spatial: false
        case .date: type.lowercased() == "year"
        default: true
        }
    }

    /// The same field with another type. Options that no longer apply go: UNSIGNED and ZEROFILL
    /// off numbers, a collation off non-text, a length the new type can't use, a default of
    /// another family, AUTO_INCREMENT off non-integers and ON UPDATE off non-timestamps.
    public func changingType(to newType: String) -> FieldDefinition {
        var field = self
        let new = newType.lowercased()
        guard new != type else { return field }
        let old = family
        field.type = new
        let family = field.family
        if !family.isNumeric { field.isUnsigned = false; field.isZerofill = false }
        if !family.hasCollation { field.charset = nil; field.collation = nil }
        if !Self.takesLength(new) || family != old {
            field.length = ""
        }
        if new == "varchar" || new == "varbinary", field.length.isEmpty { field.length = "255" }
        if !field.extra.applies(to: new) { field.extra = .none; field.onUpdatePrecision = "" }
        switch field.defaultValue {
        case .value where family != old: field.defaultValue = field.isNullable ? .null : .none
        case .expression where field.defaultValue.isTimestamp && family != .time:
            field.defaultValue = field.isNullable ? .null : .none
        case .expression where !field.defaultValue.isTimestamp && family != old:
            field.defaultValue = field.isNullable ? .null : .none
        default: break
        }
        if family == .blob || family == .json || family == .spatial || family == .text, case .value = field.defaultValue {
            field.defaultValue = field.isNullable ? .null : .none
        }
        return field
    }

    /// The column definition after ADD, CHANGE or MODIFY.
    public var sql: String {
        var parts = [SQLQuote.identifier(name)]
        var typeText = type.uppercased()
        let trimmedLength = length.trimmingCharacters(in: .whitespaces)
        if !trimmedLength.isEmpty { typeText += "(\(trimmedLength))" }
        parts.append(typeText)
        let family = self.family
        if family.isNumeric {
            if isUnsigned { parts.append("UNSIGNED") }
            if isZerofill { parts.append("ZEROFILL") }
        }
        if family.hasCollation {
            if let charset, !charset.isEmpty { parts.append("CHARACTER SET " + charset) }
            if let collation, !collation.isEmpty { parts.append("COLLATE " + collation) }
        }
        parts.append(isNullable ? "NULL" : "NOT NULL")
        if extra != .autoIncrement {
            switch defaultValue {
            case .none: break
            case .null: if isNullable { parts.append("DEFAULT NULL") }
            case .value(let value): parts.append("DEFAULT " + SQLQuote.mysqlLiteral(value))
            case .expression(let expression): parts.append("DEFAULT " + expression)
            }
        }
        switch extra {
        case .none: break
        case .autoIncrement: parts.append("AUTO_INCREMENT")
        case .onUpdate:
            // DATETIME(3) wants CURRENT_TIMESTAMP(3) for its ON UPDATE.
            let precision = onUpdatePrecision.isEmpty && Int(trimmedLength) != nil ? trimmedLength : onUpdatePrecision
            parts.append("ON UPDATE CURRENT_TIMESTAMP" + (precision.isEmpty ? "" : "(\(precision))"))
        }
        if isInvisible { parts.append("INVISIBLE") }
        if !comment.isEmpty { parts.append("COMMENT " + SQLQuote.mysqlLiteral(comment)) }
        return parts.joined(separator: " ")
    }
}

/// Where ADD or CHANGE puts a field: FIRST, AFTER another, or where it is (or at the end, for ADD).
public enum FieldPosition: Sendable, Hashable {
    case unchanged, first, after(String)

    var sql: String {
        switch self {
        case .unchanged: ""
        case .first: " FIRST"
        case .after(let name): " AFTER " + SQLQuote.identifier(name)
        }
    }
}

/// The ALTER TABLE statements Structure runs, one per change (S-023).
public enum FieldChange {
    public static func addSQL(_ field: FieldDefinition, to table: String, in database: String,
                              position: FieldPosition = .unchanged) -> String {
        "ALTER TABLE " + SQLQuote.qualified(database, table) + " ADD " + field.sql + position.sql
    }

    /// CHANGE renames too, so the old name goes first.
    public static func changeSQL(_ name: String, to field: FieldDefinition, in table: String, database: String,
                                 position: FieldPosition = .unchanged) -> String {
        "ALTER TABLE " + SQLQuote.qualified(database, table) + " CHANGE " + SQLQuote.identifier(name) + " "
            + field.sql + position.sql
    }

    /// One ALTER TABLE drops every named field.
    public static func dropSQL(_ names: [String], from table: String, in database: String) -> String {
        "ALTER TABLE " + SQLQuote.qualified(database, table) + " "
            + names.map { "DROP " + SQLQuote.identifier($0) }.joined(separator: ", ")
    }

    /// Where a field lands when it is dragged to `destination` (NSTableView's drop row, before
    /// that row), among `names` in table order; nil when it would not move.
    public static func dropPosition(moving source: Int, to destination: Int, in names: [String]) -> FieldPosition? {
        guard names.indices.contains(source), destination >= 0, destination <= names.count,
              destination != source, destination != source + 1 else { return nil }
        if destination == 0 { return .first }
        return .after(names[destination - 1])
    }

    /// Duplicate Field: "email_copy" after the original, without AUTO_INCREMENT (a table has one).
    public static func duplicate(_ field: FieldDefinition, existing: [String]) -> FieldDefinition {
        var copy = field
        copy.name = TableEdit.copyName(for: field.name, existing: existing)
        if copy.extra == .autoIncrement {
            copy.extra = .none
        }
        return copy
    }
}
