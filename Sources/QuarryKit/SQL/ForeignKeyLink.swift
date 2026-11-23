import Foundation

/// A field's way to the row it points at (S-017): the arrow in a foreign-key
/// cell opens the referenced table filtered to the cell's value.
///
/// Like Sequel Pro, a field links through the first foreign key that starts
/// with it, to that key's first referenced field. A key on several fields
/// links from its first field only.
public struct ForeignKeyLink: Sendable, Hashable {
    /// The field in this table.
    public var column: String
    public var database: String
    public var table: String
    public var referencedColumn: String

    public init(column: String, database: String, table: String, referencedColumn: String) {
        self.column = column
        self.database = database
        self.table = table
        self.referencedColumn = referencedColumn
    }

    /// One link per field, from the table's foreign keys (in name order, the first wins).
    public static func links(_ keys: [ForeignKeyInfo]) -> [String: ForeignKeyLink] {
        var links: [String: ForeignKeyLink] = [:]
        for key in keys {
            guard let column = fields(key.columns).first, let referenced = fields(key.referencedColumns).first,
                  !key.referencedTable.isEmpty, links[column] == nil else { continue }
            links[column] = ForeignKeyLink(column: column, database: key.referencedDatabase, table: key.referencedTable,
                                           referencedColumn: referenced)
        }
        return links
    }

    /// "order_id, product_id" as the client joins them.
    static func fields(_ joined: String) -> [String] {
        joined.components(separatedBy: ", ").filter { !$0.isEmpty }
    }

    /// True when a value has a row to go to: NULL points nowhere.
    public static func canFollow(_ value: CellValue) -> Bool {
        switch value {
        case .text, .binary: true
        case .null, .flag: false
        }
    }

    /// The referenced table's filter: `referenced = value`. Bytes (a raw UUID)
    /// compare as a hex literal in a WHERE clause rule, so no character set
    /// can change them on the way.
    public func filter(for value: CellValue) -> FilterTree? {
        switch value {
        case .text(let text):
            return FilterTree(RowFilter(column: referencedColumn, op: .equals, value: text))
        case .binary(let data):
            let hex = data.isEmpty ? "''" : "0x" + data.map { String(format: "%02X", $0) }.joined()
            return FilterTree(RowFilter(column: referencedColumn, op: .sql,
                                        value: SQLQuote.identifier(referencedColumn) + " = " + hex))
        case .null, .flag:
            return nil
        }
    }

    /// The arrow's hover help: "Open the customers row where id = 3".
    public func help(for value: CellValue, from database: String) -> String {
        let shown = switch value {
        case .text(let text): text.count > 40 ? String(text.prefix(40)) + "…" : text
        default: value.plainText ?? "NULL"
        }
        let place = self.database == database || self.database.isEmpty ? table : "\(self.database).\(table)"
        return "Open the \(place) row where \(referencedColumn) = \(shown)"
    }
}
