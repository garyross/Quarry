import Foundation

/// One cell of a result or table row.
public enum CellValue: Sendable, Hashable {
    case null
    case text(String)
    /// Bytes that are not text (BLOB, BINARY, or invalid UTF-8).
    case binary(Data)
    /// A yes/no value Quarry derives itself (Structure's Unsigned, Null columns).
    case flag(Bool)

    public var isNull: Bool { self == .null }

    /// The value as plain text for copying and searching. NULL is nil.
    public var plainText: String? {
        switch self {
        case .null: nil
        case .text(let string): string
        case .binary(let data): "0x" + data.map { String(format: "%02X", $0) }.joined()
        case .flag(let on): on ? "YES" : "NO"
        }
    }

    /// What a grid cell shows: long text stays whole (the cell truncates),
    /// binary shows its size ("BLOB 8 bytes").
    public var displayText: String {
        switch self {
        case .null: "NULL"
        case .text(let string): string
        case .binary(let data): "BLOB " + ByteCount.format(data.count)
        case .flag(let on): on ? "YES" : ""
        }
    }
}

/// "8 bytes", "12 KB", "3.4 MB": binary sizes for placeholders and Info.
public enum ByteCount {
    public static func format(_ bytes: Int) -> String {
        if bytes < 1024 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        return value < 10 && value != value.rounded()
            ? String(format: "%.1f %@", value, units[unit])
            : String(format: "%.0f %@", value, units[unit])
    }
}

/// A column of a result, from the server's column definition.
public struct ResultColumn: Sendable, Hashable {
    public var name: String
    /// The table the column came from (empty for expressions).
    public var table: String
    /// The database of `table` (empty for expressions).
    public var database: String
    /// The column's name in `table`, before any AS (empty for expressions).
    public var orgName: String
    public var typeName: String
    public var isBinary: Bool
    public var isNumeric: Bool
    public var isPrimaryKey: Bool
    /// How many bits a BIT column holds (S-013); nil for every other type.
    public var bitWidth: Int?

    public init(name: String, table: String = "", database: String = "", orgName: String = "", typeName: String = "",
                isBinary: Bool = false, isNumeric: Bool = false, isPrimaryKey: Bool = false, bitWidth: Int? = nil) {
        self.bitWidth = bitWidth
        self.database = database
        self.orgName = orgName
        self.name = name
        self.table = table
        self.typeName = typeName
        self.isBinary = isBinary
        self.isNumeric = isNumeric
        self.isPrimaryKey = isPrimaryKey
    }
}

/// What one statement returned.
public struct StatementResult: Sendable {
    public var sql: String
    public var columns: [ResultColumn]
    public var rows: [[CellValue]]
    /// Rows changed by INSERT/UPDATE/DELETE; nil for statements that return rows.
    public var affectedRows: Int?
    public var duration: Duration

    public init(sql: String, columns: [ResultColumn], rows: [[CellValue]], affectedRows: Int?, duration: Duration) {
        self.sql = sql
        self.columns = columns
        self.rows = rows
        self.affectedRows = affectedRows
        self.duration = duration
    }

    public var returnsRows: Bool { affectedRows == nil }

    /// The text of a cell by column name (case-insensitive), for schema results.
    public func string(_ row: Int, _ column: String) -> String? {
        guard let index = columns.firstIndex(where: { $0.name.caseInsensitiveCompare(column) == .orderedSame }),
              row < rows.count else { return nil }
        return rows[row][index].plainText
    }

    /// "1,204 rows · 0.031 s" or "3 rows affected · 0.012 s".
    public var summary: String {
        let time = Self.formatSeconds(duration)
        if let affected = affectedRows {
            return "\(Self.formatCount(affected, "row")) affected · \(time)"
        }
        return rows.isEmpty ? "No Rows · \(time)" : "\(Self.formatCount(rows.count, "row")) · \(time)"
    }

    public static func formatCount(_ count: Int, _ noun: String) -> String {
        "\(count.formatted(.number.grouping(.automatic))) \(noun)\(count == 1 ? "" : "s")"
    }

    /// "Query cancelled · 1.204 s", or "Cancelled in statement 3 of 5 · 1.204 s" for Run All (S-036).
    /// `ran` counts the statements that finished before the cancel.
    public static func cancelledStatus(ran: Int, of total: Int, after duration: Duration) -> String {
        let time = formatSeconds(duration)
        return total > 1 ? "Cancelled in statement \(min(ran + 1, total)) of \(total) · \(time)"
            : "Query cancelled · \(time)"
    }

    public static func formatSeconds(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.3f s", seconds)
    }
}
