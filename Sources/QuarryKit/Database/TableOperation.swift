import Foundation

/// Table > Maintenance (S-029): one statement for the tables selected in the
/// sidebar, and the alert's words for its result.
public enum TableOperation: String, CaseIterable, Sendable, Identifiable {
    case check, repair, analyze, optimize, flush, checksum

    public var id: String { rawValue }

    /// "Check", "Repair", …
    public var verb: String { rawValue.capitalized }

    /// For errors: "Couldn’t check “orders”".
    public var lowercased: String { rawValue }

    /// Only CHECK TABLE works on views; the others answer "is not of type 'BASE TABLE'".
    /// SQLite's integrity_check takes tables only.
    public func worksOnViews(_ engine: Engine) -> Bool { self == .check && engine == .mysql }

    /// S-072: a SQLite file has Check (`PRAGMA integrity_check(table)`) and Analyze.
    public func works(on engine: Engine) -> Bool { engine == .mysql || self == .check || self == .analyze }

    /// Analyze writes statistics, so a file opened read only can't.
    public var writesToFile: Bool { self == .analyze }

    /// SQLite's statement for one table.
    public func sqliteSQL(_ table: String) -> String? {
        switch self {
        case .check: "PRAGMA \"main\".integrity_check(\(SQLQuote.identifier(table)))"
        case .analyze: "ANALYZE \"main\".\(SQLQuote.identifier(table))"
        default: nil
        }
    }

    /// "Check Table", "Check 3 Tables", "Check View", "Check 2 Items".
    public func menuTitle(tables: Int, views: Int) -> String {
        let count = tables + views
        let noun = views == 0 ? "Table" : tables == 0 ? "View" : "Item"
        return count > 1 ? "\(verb) \(count) \(noun)s" : "\(verb) \(noun)"
    }

    /// One statement for every table: `CHECK TABLE `db`.`a`, `db`.`b``.
    public func sql(_ tables: [String], in database: String) -> String {
        let list = tables.map { SQLQuote.qualified(database, $0) }.joined(separator: ", ")
        return "\(rawValue.uppercased()) TABLE \(list)"
    }

    /// Splits the server's rows (`Table` is "database.table") into one result
    /// per requested table, in the order asked. A table with no rows gets "No result".
    public func results(tables: [String], in database: String,
                        rows: [(table: String, type: String, text: String)]) -> [TableCheck] {
        tables.map { table in
            let key = "\(database).\(table)"
            let own = rows.filter { $0.table.caseInsensitiveCompare(key) == .orderedSame || $0.table == table }
            guard !own.isEmpty else { return TableCheck(table: table, severity: .warning, message: "No result") }
            return TableCheck.parse(table: table, rows: own.map { (type: $0.type, text: $0.text) })
        }
    }

    /// CHECKSUM TABLE's rows: a number, or NULL when the table is gone.
    public static func checksums(tables: [String], in database: String,
                                 rows: [(table: String, checksum: String?)]) -> [TableCheck] {
        tables.map { table in
            let key = "\(database).\(table)"
            let row = rows.first { $0.table.caseInsensitiveCompare(key) == .orderedSame || $0.table == table }
            guard let value = row?.checksum else {
                return TableCheck(table: table, severity: .error, message: "No checksum: the table doesn’t exist")
            }
            return TableCheck(table: table, severity: .ok, message: value)
        }
    }

    /// The alert's title: "Check “orders”", "Check 3 Tables".
    public func alertTitle(_ results: [TableCheck]) -> String {
        guard results.count == 1, let one = results.first else { return "\(verb) \(results.count) Tables" }
        return "\(verb) \u{201C}\(one.table)\u{201D}"
    }

    /// The alert's message. One table: its message. Several: a summary line
    /// (not for Checksum, whose numbers are the answer), then "name: message"
    /// per table, at most `limit` lines and "…and 4 more".
    public func alertMessage(_ results: [TableCheck], limit: Int = 30) -> String {
        if results.count == 1, let one = results.first { return one.message }
        var lines: [String] = []
        if self != .checksum {
            let bad = results.filter { $0.severity > .info }.count
            lines.append(bad == 0 ? "All \(results.count) tables are OK."
                : "\(bad) of \(results.count) tables \(bad == 1 ? "has a problem" : "have problems").")
            lines.append("")
        }
        lines += results.prefix(limit).map { "\($0.table): \($0.message)" }
        if results.count > limit { lines.append("…and \(results.count - limit) more") }
        return lines.joined(separator: "\n")
    }
}
