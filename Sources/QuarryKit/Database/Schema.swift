import Foundation

/// What a sidebar object is.
public enum ObjectKind: String, Sendable, CaseIterable, Codable {
    case table, view, procedure, function

    /// From SHOW FULL TABLES' Table_type, or information_schema.ROUTINES' ROUTINE_TYPE.
    public init?(serverType: String) {
        switch serverType.uppercased() {
        case "BASE TABLE", "SYSTEM VERSIONED", "SEQUENCE": self = .table
        case "VIEW", "SYSTEM VIEW": self = .view
        case "PROCEDURE": self = .procedure
        case "FUNCTION": self = .function
        default: return nil
        }
    }

    public var hasRows: Bool { self == .table || self == .view }
}

/// A table, view, procedure or function in the sidebar.
public struct DBObject: Sendable, Hashable, Identifiable {
    public var name: String
    public var kind: ObjectKind
    public var id: String { "\(kind.rawValue):\(name)" }

    /// Tables, then views, then routines; each by name, ignoring case.
    public static func sorted(_ objects: [DBObject]) -> [DBObject] {
        objects.sorted { ($0.kind.sortOrder, $0.name.lowercased()) < ($1.kind.sortOrder, $1.name.lowercased()) }
    }

    public init(name: String, kind: ObjectKind) {
        self.name = name
        self.kind = kind
    }

    /// Case-insensitive "contains", the sidebar filter.
    public func matches(_ filter: String) -> Bool {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || name.localizedCaseInsensitiveContains(trimmed)
    }
}

/// A field from SHOW FULL COLUMNS.
public struct FieldInfo: Sendable, Hashable {
    public var name: String
    /// The full type as the server prints it: "int(10) unsigned zerofill".
    public var fullType: String
    public var baseType: String
    /// What sits in the parentheses: "10", "10,2", "'a','b'".
    public var length: String
    public var isUnsigned: Bool
    public var isZerofill: Bool
    public var isNullable: Bool
    /// PRI, UNI, MUL, or empty.
    public var key: String
    /// nil when there is no default; "NULL" when the default is NULL.
    public var defaultValue: String?
    public var extra: String
    public var collation: String?
    public var comment: String

    public init(name: String, fullType: String, isNullable: Bool, key: String, defaultValue: String?,
                extra: String, collation: String?, comment: String) {
        self.name = name
        self.fullType = fullType
        let parsed = FieldInfo.parseType(fullType)
        baseType = parsed.base
        length = parsed.length
        isUnsigned = parsed.unsigned
        isZerofill = parsed.zerofill
        self.isNullable = isNullable
        self.key = key
        self.defaultValue = defaultValue
        self.extra = extra
        self.collation = collation
        self.comment = comment
    }

    /// How many bits a BIT field holds; nil for other types.
    public var bitWidth: Int? { baseType == "bit" ? BitValue.width(fromLength: length) : nil }

    /// "decimal(10,2) unsigned" -> ("decimal", "10,2", unsigned: true, zerofill: false)
    public static func parseType(_ type: String) -> (base: String, length: String, unsigned: Bool, zerofill: Bool) {
        var base = type
        var length = ""
        var rest = ""
        if let open = type.firstIndex(of: "("), let close = closingParen(in: type, from: open) {
            base = String(type[..<open])
            length = String(type[type.index(after: open)..<close])
            rest = String(type[type.index(after: close)...])
        } else if let space = type.firstIndex(of: " ") {
            base = String(type[..<space])
            rest = String(type[space...])
        }
        let words = Set(rest.lowercased().split(separator: " ").map(String.init))
        return (base.lowercased().trimmingCharacters(in: .whitespaces), length,
                words.contains("unsigned"), words.contains("zerofill"))
    }

    /// The ")" that closes the "(" at `open`, skipping quoted enum values like 'a)b'.
    private static func closingParen(in type: String, from open: String.Index) -> String.Index? {
        var inQuote = false
        var index = type.index(after: open)
        while index < type.endIndex {
            let character = type[index]
            if character == "'" { inQuote.toggle() }
            if character == ")" && !inQuote { return index }
            index = type.index(after: index)
        }
        return nil
    }
}

/// A foreign key with its columns joined: "customer_id" or "order_id, product_id".
public struct ForeignKeyInfo: Sendable, Hashable {
    public var name: String
    public var columns: String
    public var referencedDatabase: String
    public var referencedTable: String
    public var referencedColumns: String
    public var onUpdate: String
    public var onDelete: String
}

/// Rows per page and where a page starts. "Rows 1–1,000 of 48,213".
public struct Paging: Sendable, Equatable {
    public var total: Int
    public var pageSize: Int
    /// 0-based.
    public var page: Int

    public init(total: Int, pageSize: Int, page: Int = 0) {
        self.total = max(0, total)
        self.pageSize = max(1, pageSize)
        self.page = 0
        self.page = min(max(0, page), max(0, pageCount - 1))
    }

    public var pageCount: Int { max(1, (total + pageSize - 1) / pageSize) }
    public var offset: Int { page * pageSize }
    public var hasPrevious: Bool { page > 0 }
    public var hasNext: Bool { page + 1 < pageCount }
    public var firstRow: Int { total == 0 ? 0 : offset + 1 }
    public var lastRow: Int { min(total, offset + pageSize) }

    public func moved(by pages: Int) -> Paging { Paging(total: total, pageSize: pageSize, page: page + pages) }

    /// "Rows 1–1,000 of 48,213", or "No Rows".
    public var label: String {
        guard total > 0 else { return "No Rows" }
        let style = IntegerFormatStyle<Int>.number.grouping(.automatic)
        return "Rows \(firstRow.formatted(style))–\(lastRow.formatted(style)) of \(total.formatted(style))"
    }

    /// With a filter: "312 of 100,000 rows", and the page's range when there
    /// is more than one page: "Rows 1–1,000 · 5,312 of 100,000 rows".
    public func filteredLabel(unfiltered: Int) -> String {
        let style = IntegerFormatStyle<Int>.number.grouping(.automatic)
        let count = "\(total.formatted(style)) of \(unfiltered.formatted(style)) \(unfiltered == 1 ? "row" : "rows")"
        guard pageCount > 1 else { return count }
        return "Rows \(firstRow.formatted(style))–\(lastRow.formatted(style)) · " + count
    }
}

/// "…near 'oops' at line 2" -> 2 (the line inside the statement).
public enum ServerMessage {
    public static func line(in message: String) -> Int? {
        guard let range = message.range(of: "at line ", options: .backwards) else { return nil }
        let digits = message[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}
