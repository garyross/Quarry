import Foundation

/// One table's row from SHOW TABLE STATUS, as Info (⌘5) shows it (S-027).
public struct TableStatus: Sendable, Equatable {
    public var engine: String
    public var rowFormat: String
    /// An estimate for InnoDB.
    public var rows: Int?
    public var averageRowLength: Int?
    public var dataLength: Int?
    public var maxDataLength: Int?
    public var indexLength: Int?
    public var dataFree: Int?
    /// Nil when the table has no AUTO_INCREMENT field.
    public var autoIncrement: Int?
    public var collation: String
    public var created: String
    public var updated: String
    public var comment: String

    public init(engine: String = "", rowFormat: String = "", rows: Int? = nil, averageRowLength: Int? = nil,
                dataLength: Int? = nil, maxDataLength: Int? = nil, indexLength: Int? = nil, dataFree: Int? = nil,
                autoIncrement: Int? = nil, collation: String = "", created: String = "", updated: String = "",
                comment: String = "") {
        self.engine = engine
        self.rowFormat = rowFormat
        self.rows = rows
        self.averageRowLength = averageRowLength
        self.dataLength = dataLength
        self.maxDataLength = maxDataLength
        self.indexLength = indexLength
        self.dataFree = dataFree
        self.autoIncrement = autoIncrement
        self.collation = collation
        self.created = created
        self.updated = updated
        self.comment = comment
    }

    /// The first row of SHOW TABLE STATUS; nil when there is none.
    public init?(_ result: StatementResult) {
        guard !result.rows.isEmpty else { return nil }
        func text(_ name: String) -> String { result.string(0, name) ?? "" }
        func number(_ name: String) -> Int? { Int(text(name)) }
        self.init(engine: text("Engine"), rowFormat: text("Row_format"), rows: number("Rows"),
                  averageRowLength: number("Avg_row_length"), dataLength: number("Data_length"),
                  maxDataLength: number("Max_data_length"), indexLength: number("Index_length"),
                  dataFree: number("Data_free"), autoIncrement: number("Auto_increment"),
                  collation: text("Collation"), created: text("Create_time"), updated: text("Update_time"),
                  comment: text("Comment"))
    }

    /// The character set the collation belongs to: looked up in the catalog,
    /// else the part before the first underscore.
    public func charset(in catalog: CharsetCatalog?) -> String {
        if let catalog, let match = catalog.collations.first(where: { $0.value.contains(collation) }) {
            return match.key
        }
        return collation.split(separator: "_").first.map(String.init) ?? ""
    }
}

/// One change Info makes with ALTER TABLE (S-027), as Sequel Pro's
/// extended table info did: each control runs its own statement.
public enum TableOption: Sendable, Equatable {
    case engine(String)
    /// The table's default for new fields; existing fields keep theirs.
    case charset(String)
    case collation(String)
    case comment(String)
    case autoIncrement(Int)

    public func sql(table: String, database: String) -> String {
        let alter = "ALTER TABLE " + SQLQuote.qualified(database, table) + " "
        let clause = switch self {
        case .engine(let engine): "ENGINE = " + SQLQuote.identifier(engine)
        case .charset(let charset): "CHARACTER SET = " + SQLQuote.identifier(charset)
        case .collation(let collation): "COLLATE = " + SQLQuote.identifier(collation)
        case .comment(let comment): "COMMENT = " + SQLQuote.mysqlLiteral(comment)
        case .autoIncrement(let value): "AUTO_INCREMENT = \(value)"
        }
        return alter + clause
    }

    /// An auto-increment value typed into Info: digits, commas allowed; nil when it isn't a whole number ≥ 1.
    public static func autoIncrement(from text: String) -> Int? {
        let digits = text.filter { $0 != "," && $0 != " " && $0 != "\u{202F}" }
        guard let value = Int(digits), value >= 1 else { return nil }
        return value
    }
}
