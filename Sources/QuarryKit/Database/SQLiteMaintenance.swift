import Foundation

// S-072: the Database Information panel for a SQLite file. Plain data and
// pure rules; `DatabaseClient+SQLiteMaintenance` fills them in.

/// What the top of the panel shows for a SQLite file.
public struct SQLiteFileInfo: Sendable, Equatable {
    public var fileName: String
    /// The main file on disk (a -wal file beside it is not counted).
    public var fileBytes: Int
    public var pageSize: Int
    public var pageCount: Int
    public var freePages: Int
    /// "wal", "delete", …
    public var journalMode: String
    /// "UTF-8", "UTF-16le", …
    public var encoding: String
    public var foreignKeys: Bool
    /// "3.51.0"
    public var version: String
    public var tables: [String]
    public var viewCount: Int
    public var indexCount: Int
    public var triggerCount: Int
    /// Opened read only: Vacuum, Analyze and Optimize gray out.
    public var isReadOnly: Bool

    public init(fileName: String, fileBytes: Int, pageSize: Int, pageCount: Int, freePages: Int, journalMode: String,
                encoding: String, foreignKeys: Bool, version: String, tables: [String], viewCount: Int = 0,
                indexCount: Int = 0, triggerCount: Int = 0, isReadOnly: Bool = false) {
        self.fileName = fileName
        self.fileBytes = fileBytes
        self.pageSize = pageSize
        self.pageCount = pageCount
        self.freePages = freePages
        self.journalMode = journalMode
        self.encoding = encoding
        self.foreignKeys = foreignKeys
        self.version = version
        self.tables = tables
        self.viewCount = viewCount
        self.indexCount = indexCount
        self.triggerCount = triggerCount
        self.isReadOnly = isReadOnly
    }

    /// Bytes in free pages, which Vacuum gives back.
    public var freeBytes: Int { freePages * pageSize }
    /// 0...1 of the file's pages that are free.
    public var freeShare: Double { pageCount == 0 ? 0 : Double(freePages) / Double(pageCount) }

    /// "6 tables · 1 view · 1 trigger", as short as a server's "tables · views · routines".
    public var countsLine: String {
        [StatementResult.formatCount(tables.count, "table"), StatementResult.formatCount(viewCount, "view"),
         StatementResult.formatCount(triggerCount, "trigger")].joined(separator: " · ")
    }

    /// "5 indexes"
    public var indexesLine: String { "\(indexCount.formatted()) \(indexCount == 1 ? "index" : "indexes")" }

    /// "1,024 × 4 KB, 12 free"
    public var pagesLine: String {
        "\(pageCount.formatted()) × \(ByteCount.format(pageSize)), \(freePages.formatted()) free"
    }

    /// "WAL", "Delete"
    public var journalTitle: String {
        journalMode.lowercased() == "wal" ? "WAL" : journalMode.capitalized
    }

    /// The Vacuum dialog's words.
    public var vacuumMessage: String {
        let gain = freeBytes > 0 ? "give back \(ByteCount.format(freeBytes)) of free pages"
            : "pack its pages tightly. It has no free pages, so it won’t get much smaller"
        return "SQLite rewrites the file to \(gain). Other apps can’t write to it until it’s done."
    }

    /// "demo.sqlite went from 48 MB to 36 MB."
    public static func vacuumResult(_ name: String, before: Int, after: Int) -> String {
        "\(name) went from \(ByteCount.format(before)) to \(ByteCount.format(after))."
    }
}

/// A foreign key, as `PRAGMA foreign_key_list` gives it.
public struct SQLiteForeignKey: Sendable, Equatable {
    public var table: String
    public var columns: [String]
    public var parent: String
    /// Empty when it refers to the parent's primary key.
    public var parentColumns: [String]

    public init(table: String, columns: [String], parent: String, parentColumns: [String] = []) {
        self.table = table
        self.columns = columns
        self.parent = parent
        self.parentColumns = parentColumns
    }
}

/// One row of `PRAGMA foreign_key_check`: a row whose parent row is missing.
public struct SQLiteKeyProblem: Sendable, Equatable {
    public var table: String
    public var rowid: Int?
    public var parent: String

    public init(table: String, rowid: Int?, parent: String) {
        self.table = table
        self.rowid = rowid
        self.parent = parent
    }
}

/// Everything the SQLite Health Check reads.
public struct SQLiteHealthInput: Sendable {
    public var info: SQLiteFileInfo
    public var tablesWithPrimaryKey: Set<String>
    public var foreignKeys: [SQLiteForeignKey]
    /// Each table's indexes as column lists, its primary key among them.
    public var indexes: [String: [[String]]]
    /// Rows with a missing parent, and tables whose check failed (by table).
    public var keyProblems: [TableCheck]

    public init(info: SQLiteFileInfo, tablesWithPrimaryKey: Set<String>, foreignKeys: [SQLiteForeignKey],
                indexes: [String: [[String]]], keyProblems: [TableCheck]) {
        self.info = info
        self.tablesWithPrimaryKey = tablesWithPrimaryKey
        self.foreignKeys = foreignKeys
        self.indexes = indexes
        self.keyProblems = keyProblems
    }
}

public enum SQLiteHealthCheck {
    /// Free pages are flagged above this share of the file.
    public static let freeShare = 0.25

    /// The findings, worst first. One `.ok` finding when nothing is wrong.
    public static func run(_ input: SQLiteHealthInput) -> [Finding] {
        var findings: [Finding] = []
        let quote = { (name: String) in SQLQuote.identifier(name) }

        let broken = input.keyProblems.filter { $0.severity > .ok }
        if !broken.isEmpty {
            findings.append(Finding(
                id: "foreign-key-errors", severity: .error,
                title: "\(StatementResult.formatCount(broken.count, "table")) \(broken.count == 1 ? "fails" : "fail") the foreign key check",
                detail: broken.map { "\($0.table): \($0.message)" }.joined(separator: "\n"),
                tables: broken.map(\.table),
                sql: broken.map { "PRAGMA foreign_key_check(\(quote($0.table)));" }.joined(separator: "\n")))
        }

        if input.info.freeShare > freeShare {
            findings.append(Finding(
                id: "free-pages", severity: .info,
                title: "\(Int(input.info.freeShare * 100))% of the file is free pages",
                detail: "\(ByteCount.format(input.info.freeBytes)) is allocated but unused. Vacuum rewrites the file to give it back."))
        }

        let referenced = Set(input.foreignKeys.filter(\.parentColumns.isEmpty).map(\.parent))
        let noKey = input.info.tables.filter { referenced.contains($0) && !input.tablesWithPrimaryKey.contains($0) }
        if !noKey.isEmpty {
            findings.append(Finding(
                id: "referenced-no-key", severity: .warning,
                title: "\(StatementResult.formatCount(noKey.count, "table")) other tables refer to \(noKey.count == 1 ? "has" : "have") no primary key",
                detail: "A foreign key that names only the table refers to its primary key. Without one, SQLite stops "
                    + "inserts and deletes on those tables with \u{201C}foreign key mismatch\u{201D}. Add a primary key.",
                tables: noKey))
        }

        let unindexed = input.foreignKeys.filter { !isIndexed($0, indexes: input.indexes[$0.table] ?? []) }
        if !unindexed.isEmpty {
            findings.append(Finding(
                id: "foreign-key-index", severity: .warning,
                title: "\(StatementResult.formatCount(unindexed.count, "foreign key")) \(unindexed.count == 1 ? "has" : "have") no index",
                detail: "Deleting or changing a parent row then reads the whole child table to check it. "
                    + unindexed.map { "\($0.table).\($0.columns.joined(separator: ", ")) refers to \($0.parent)." }.joined(separator: " "),
                tables: Array(Set(unindexed.map(\.table))).sorted(),
                sql: unindexed.map { key in
                    "CREATE INDEX \(quote(indexName(key))) ON \(quote(key.table)) (\(key.columns.map(quote).joined(separator: ", ")));"
                }.joined(separator: "\n")))
        }

        if findings.isEmpty {
            findings.append(Finding(id: "ok", severity: .ok, title: "No problems found",
                                    detail: input.info.tables.isEmpty ? "The file has no tables yet."
                                        : "Checked \(StatementResult.formatCount(input.info.tables.count, "table")) for foreign key errors, "
                                            + "free pages, primary keys and indexes on foreign keys."))
        }
        return findings.enumerated().sorted { ($1.element.severity, $0.offset) < ($0.element.severity, $1.offset) }.map(\.element)
    }

    /// An index (or the primary key) whose first columns are the key's columns, in any order.
    public static func isIndexed(_ key: SQLiteForeignKey, indexes: [[String]]) -> Bool {
        let wanted = Set(key.columns.map { $0.lowercased() })
        return indexes.contains { index in
            index.count >= wanted.count && Set(index.prefix(wanted.count).map { $0.lowercased() }) == wanted
        }
    }

    /// "order_items_product_id_idx"
    public static func indexName(_ key: SQLiteForeignKey) -> String {
        ([key.table] + key.columns + ["idx"]).joined(separator: "_")
    }
}

/// Reads `PRAGMA integrity_check` and `PRAGMA foreign_key_check` into one result per table.
public enum SQLiteIntegrity {
    /// Integrity Check's messages, by the table or index they name. "ok" alone
    /// means no problems. A message that names nothing known goes under the file.
    public static func results(messages: [String], fileName: String, tables: [String],
                               indexes: [String: String]) -> [TableCheck] {
        let problems = messages.filter { $0.lowercased() != "ok" && !$0.isEmpty }
        guard !problems.isEmpty else { return [] }
        let byLength = { (a: String, b: String) in a.count > b.count }
        let indexNames = indexes.keys.sorted(by: byLength)
        let tableNames = tables.sorted(by: byLength)
        var order: [String] = []
        var grouped: [String: [String]] = [:]
        for message in problems {
            let words = Set(message.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map { $0.lowercased() })
            func named(_ name: String) -> Bool {
                words.contains(name.lowercased()) || (name.contains(" ") && message.contains(name))
            }
            let table = indexNames.first(where: named).flatMap { indexes[$0] } ?? tableNames.first(where: named) ?? fileName
            if grouped[table] == nil { order.append(table) }
            grouped[table, default: []].append(message)
        }
        return order.map { table in
            let lines = grouped[table] ?? []
            let more = lines.count > 1 ? " (and \(lines.count - 1) more)" : ""
            return TableCheck(table: table, severity: .error, message: lines[0] + more)
        }
    }

    /// Foreign Key Check's rows for one table: "2 rows refer to missing rows in customers".
    public static func keyCheck(table: String, problems: [SQLiteKeyProblem]) -> TableCheck {
        let own = problems.filter { $0.table == table }
        guard !own.isEmpty else { return TableCheck(table: table, severity: .ok, message: "OK") }
        var parents: [String] = []
        for problem in own where !parents.contains(problem.parent) { parents.append(problem.parent) }
        let lines = parents.map { parent in
            let rows = own.filter { $0.parent == parent }
            let ids = rows.compactMap(\.rowid).prefix(5).map(String.init).joined(separator: ", ")
            let count = rows.count
            return "\(StatementResult.formatCount(count, "row")) \(count == 1 ? "refers" : "refer") to missing rows in \(parent)"
                + (ids.isEmpty ? "" : " (rowid \(ids)\(count > 5 ? ", …" : ""))")
        }
        return TableCheck(table: table, severity: .error, message: lines.joined(separator: "; "))
    }
}
