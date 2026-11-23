import Foundation

// The Database Information panel: an overview of one database, and the
// maintenance tools people rarely remember the SQL for. Everything here is
// plain data and pure functions; `DatabaseClient+Maintenance` fills it in.

/// One base table or view, from `information_schema.TABLES`.
public struct TableStat: Sendable, Equatable {
    public var name: String
    public var isView: Bool
    public var engine: String?
    /// The server's estimate. InnoDB counts are approximate.
    public var rows: Int?
    public var dataBytes: Int
    public var indexBytes: Int
    /// Space allocated but unused (reclaimable with OPTIMIZE TABLE).
    public var freeBytes: Int
    public var collation: String?

    public init(name: String, isView: Bool = false, engine: String? = "InnoDB", rows: Int? = 0, dataBytes: Int = 0,
                indexBytes: Int = 0, freeBytes: Int = 0, collation: String? = nil) {
        self.name = name
        self.isView = isView
        self.engine = engine
        self.rows = rows
        self.dataBytes = dataBytes
        self.indexBytes = indexBytes
        self.freeBytes = freeBytes
        self.collation = collation
    }

    /// InnoDB tables are rebuilt rather than repaired.
    public var isInnoDB: Bool { engine?.caseInsensitiveCompare("InnoDB") == .orderedSame }
}

/// What the top of the Database Information panel shows.
public struct DatabaseOverview: Sendable, Equatable {
    public var name: String
    public var charset: String
    public var collation: String
    /// Base tables and views, by name.
    public var objects: [TableStat]
    /// nil when routines could not be read (see `routinesError`).
    public var routineCount: Int?
    public var routinesError: DatabaseError?

    public init(name: String, charset: String, collation: String, objects: [TableStat],
                routineCount: Int?, routinesError: DatabaseError? = nil) {
        self.name = name
        self.charset = charset
        self.collation = collation
        self.objects = objects
        self.routineCount = routineCount
        self.routinesError = routinesError
    }

    public var tables: [TableStat] { objects.filter { !$0.isView } }
    public var viewCount: Int { objects.count - tables.count }
    public var dataBytes: Int { tables.reduce(0) { $0 + $1.dataBytes } }
    public var indexBytes: Int { tables.reduce(0) { $0 + $1.indexBytes } }
    public var rows: Int { tables.reduce(0) { $0 + ($1.rows ?? 0) } }

    /// Engines by how many tables use them, most first: [("InnoDB", 57), ("MyISAM", 2)].
    public var engines: [(name: String, count: Int)] {
        let counts = Dictionary(grouping: tables.compactMap(\.engine), by: { $0 }).mapValues(\.count)
        return counts.map { ($0.key, $0.value) }.sorted { ($1.count, $0.name) < ($0.count, $1.name) }
    }

    /// "59 tables · 3 views · 4 routines"
    public var countsLine: String {
        var parts = [Self.plural(tables.count, "table"), Self.plural(viewCount, "view")]
        if let routineCount { parts.append(Self.plural(routineCount, "routine")) }
        return parts.joined(separator: " · ")
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        StatementResult.formatCount(count, noun)
    }
}

/// How serious a result is. Ordered, so the worst of several is `max()`.
public enum Severity: Int, Sendable, Comparable, CaseIterable {
    case ok, info, warning, error
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

// MARK: Check and repair

/// One table's result from CHECK TABLE or a repair.
public struct TableCheck: Sendable, Equatable, Identifiable {
    public var table: String
    public var severity: Severity
    /// The server's words: "OK", "Table is marked as crashed", …
    public var message: String
    public var id: String { table }

    public init(table: String, severity: Severity, message: String) {
        self.table = table
        self.severity = severity
        self.message = message
    }

    /// Reads the rows of CHECK TABLE or REPAIR TABLE (`Table`, `Op`,
    /// `Msg_type`, `Msg_text`). The last `status` row is the verdict; error
    /// and warning rows before it say why.
    public static func parse(table: String, rows: [(type: String, text: String)]) -> TableCheck {
        let fine = ["ok", "table is already up to date"]
        var worst = Severity.ok
        var reason: String?
        for row in rows {
            switch row.type.lowercased() {
            case "error":
                worst = max(worst, .error)
                reason = reason ?? row.text
            case "warning":
                worst = max(worst, .warning)
                reason = reason ?? row.text
            case "status":
                if !fine.contains(row.text.lowercased()) {
                    worst = max(worst, .error)
                    reason = reason ?? row.text
                }
            default:
                break
            }
        }
        let status = rows.last { $0.type.lowercased() == "status" }?.text
        return TableCheck(table: table, severity: worst, message: reason ?? status ?? "OK")
    }
}

// MARK: Character sets and collations

/// A text column's character set and collation.
public struct ColumnCharset: Sendable, Equatable {
    public var table: String
    public var column: String
    public var charset: String
    public var collation: String

    public init(table: String, column: String, charset: String, collation: String) {
        self.table = table
        self.column = column
        self.charset = charset
        self.collation = collation
    }
}

public enum Charsets {
    /// utf8mb3, written "utf8" by older servers: three bytes at most, so no
    /// emoji and no rarer CJK characters. Deprecated by MySQL.
    public static func isUTF8MB3(_ name: String) -> Bool {
        let name = name.lowercased()
        return name == "utf8" || name.hasPrefix("utf8_") || name.hasPrefix("utf8mb3")
    }

    /// Whether the character set can hold any Unicode character.
    public static func isFullUnicode(_ charset: String) -> Bool {
        let name = charset.lowercased()
        return name == "utf8mb4" || name == "utf16" || name == "utf16le" || name == "utf32" || name == "binary"
    }

    /// The utf8mb4 collation that sorts and compares like `collation`:
    /// utf8mb3_unicode_ci -> utf8mb4_unicode_ci.
    public static func utf8mb4Equivalent(of collation: String) -> String {
        let lower = collation.lowercased()
        for prefix in ["utf8mb3_", "utf8_"] where lower.hasPrefix(prefix) {
            return "utf8mb4_" + collation.dropFirst(prefix.count)
        }
        return "utf8mb4_unicode_ci"
    }
}

/// One collation and where it is used.
public struct CollationUse: Sendable, Equatable, Identifiable {
    public var collation: String
    public var charset: String
    public var columns: Int
    public var tables: [String]
    public var id: String { collation }

    public var isUTF8MB3: Bool { Charsets.isUTF8MB3(charset) }
    public var isFullUnicode: Bool { Charsets.isFullUnicode(charset) }
    public var severity: Severity { isUTF8MB3 ? .warning : isFullUnicode ? .ok : .info }
}

/// The result of Find Collations.
public struct CollationReport: Sendable, Equatable {
    public var database: String
    public var defaultCharset: String
    public var defaultCollation: String
    /// Most-used first.
    public var uses: [CollationUse]
    /// Tables with a utf8mb3 column or a utf8mb3 table default, and the
    /// utf8mb4 collation each should convert to.
    public var tablesToConvert: [(table: String, collation: String)]

    public static func == (a: CollationReport, b: CollationReport) -> Bool {
        a.database == b.database && a.defaultCharset == b.defaultCharset && a.defaultCollation == b.defaultCollation
            && a.uses == b.uses && a.tablesToConvert.map(\.table) == b.tablesToConvert.map(\.table)
            && a.tablesToConvert.map(\.collation) == b.tablesToConvert.map(\.collation)
    }

    public init(database: String, defaultCharset: String, defaultCollation: String,
                columns: [ColumnCharset], tables: [TableStat]) {
        self.database = database
        self.defaultCharset = defaultCharset
        self.defaultCollation = defaultCollation
        let grouped = Dictionary(grouping: columns, by: \.collation)
        uses = grouped.map { collation, columns in
            CollationUse(collation: collation, charset: columns[0].charset, columns: columns.count,
                         tables: Array(Set(columns.map(\.table))).sorted())
        }
        .sorted { ($1.columns, $0.collation) < ($0.columns, $1.collation) }

        var convert: [String: String] = [:]
        for column in columns where Charsets.isUTF8MB3(column.charset) {
            convert[column.table] = convert[column.table] ?? Charsets.utf8mb4Equivalent(of: column.collation)
        }
        for table in tables where !table.isView {
            if let collation = table.collation, Charsets.isUTF8MB3(collation), convert[table.name] == nil {
                convert[table.name] = Charsets.utf8mb4Equivalent(of: collation)
            }
        }
        tablesToConvert = convert.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    public var usesUTF8MB3: Bool { !tablesToConvert.isEmpty || Charsets.isUTF8MB3(defaultCharset) }

    /// ALTER statements that move every utf8mb3 table (and the database
    /// default) to utf8mb4, keeping each collation's sorting rules. nil when
    /// nothing uses utf8mb3.
    public var conversionSQL: String? {
        guard usesUTF8MB3 else { return nil }
        var lines = [
            "-- Convert utf8mb3 to utf8mb4 in \(database). Back up first: each ALTER rebuilds",
            "-- the table and locks it while it runs, and TEXT columns may grow to MEDIUMTEXT.",
        ]
        if Charsets.isUTF8MB3(defaultCharset) {
            lines.append("ALTER DATABASE \(SQLQuote.identifier(database)) CHARACTER SET utf8mb4 COLLATE "
                         + "\(Charsets.utf8mb4Equivalent(of: defaultCollation));")
        }
        for (table, collation) in tablesToConvert {
            lines.append("ALTER TABLE \(SQLQuote.qualified(database, table)) CONVERT TO CHARACTER SET utf8mb4 COLLATE \(collation);")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: Health check

/// One thing the Health Check found.
public struct Finding: Sendable, Equatable, Identifiable {
    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String
    /// The tables it applies to, if any.
    public var tables: [String]
    /// Statements that fix it, for the Query editor. People review and run them.
    public var sql: String?

    public init(id: String, severity: Severity, title: String, detail: String, tables: [String] = [], sql: String? = nil) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.tables = tables
        self.sql = sql
    }
}

/// An auto-increment column and the next value it will hand out.
public struct AutoIncrementColumn: Sendable, Equatable {
    public var table: String
    public var column: String
    /// "int(11) unsigned"
    public var type: String
    public var next: Int

    public init(table: String, column: String, type: String, next: Int) {
        self.table = table
        self.column = column
        self.type = type
        self.next = next
    }

    /// The largest value the column's integer type holds.
    public var maximum: Double? {
        let lower = type.lowercased()
        let unsigned = lower.contains("unsigned")
        let base = lower.prefix { $0.isLetter }
        let bits: Double? = switch base {
        case "tinyint": 8
        case "smallint": 16
        case "mediumint": 24
        case "int", "integer": 32
        case "bigint": 64
        default: nil
        }
        guard let bits else { return nil }
        return pow(2, unsigned ? bits : bits - 1) - 1
    }

    /// 0...1: how much of the type's range is used.
    public var used: Double? { maximum.map { Double(next) / $0 } }
}

/// Everything the Health Check reads, gathered by `DatabaseClient.healthInput`.
public struct HealthInput: Sendable {
    public var overview: DatabaseOverview
    public var columns: [ColumnCharset]
    public var tablesWithPrimaryKey: Set<String>
    public var autoIncrements: [AutoIncrementColumn]
    public var isMariaDB: Bool

    public init(overview: DatabaseOverview, columns: [ColumnCharset], tablesWithPrimaryKey: Set<String>,
                autoIncrements: [AutoIncrementColumn], isMariaDB: Bool) {
        self.overview = overview
        self.columns = columns
        self.tablesWithPrimaryKey = tablesWithPrimaryKey
        self.autoIncrements = autoIncrements
        self.isMariaDB = isMariaDB
    }
}

public enum HealthCheck {
    /// A table counts as fragmented above this much free space…
    public static let fragmentedBytes = 10 * 1024 * 1024
    /// …when that is also this share of its size.
    public static let fragmentedShare = 0.2
    /// An auto-increment column is flagged above this share of its range.
    public static let autoIncrementShare = 0.75

    /// The findings, worst first. One `.ok` finding when nothing is wrong.
    public static func run(_ input: HealthInput) -> [Finding] {
        let database = input.overview.name
        let tables = input.overview.tables
        var findings: [Finding] = []

        if let error = input.overview.routinesError {
            let upgrade = error.code == 1558 || error.code == 1805 || error.message.localizedCaseInsensitiveContains("upgrade")
            findings.append(upgrade
                ? Finding(id: "system-tables", severity: .error, title: "The server's system tables need upgrading",
                          detail: "Procedures and functions can't be read until they are. In Terminal, run "
                              + (input.isMariaDB ? "mariadb-upgrade -u root -p --upgrade-system-tables"
                                                 : "mysql_upgrade -u root -p (MySQL 8.0.16 and later upgrade on restart)")
                              + ". It changes only the mysql system database.\n\n" + error.message)
                : Finding(id: "routines", severity: .warning, title: "Procedures and functions can't be read",
                          detail: error.message))
        }

        let noKey = tables.map(\.name).filter { !input.tablesWithPrimaryKey.contains($0) }
        if !noKey.isEmpty {
            findings.append(Finding(
                id: "primary-key", severity: .warning,
                title: "\(DatabaseOverview.plural(noKey.count, "table")) \(noKey.count == 1 ? "has" : "have") no primary key",
                detail: "Without one, rows can't be told apart reliably: editing rows, replication and many tools need it. "
                    + "Add an id column, or make a unique column the primary key.",
                tables: noKey))
        }

        let crashProne = tables.filter { ["myisam", "aria"].contains($0.engine?.lowercased() ?? "") }
        if !crashProne.isEmpty {
            let engineNames = Set(crashProne.compactMap(\.engine)).sorted()
            let engines = engineNames.joined(separator: " and ")
            findings.append(Finding(
                id: "engine", severity: .warning,
                title: "\(DatabaseOverview.plural(crashProne.count, "table")) \(crashProne.count == 1 ? "uses" : "use") \(engines)",
                detail: "\(engines) \(engineNames.count == 1 ? "has" : "have") no transactions or foreign keys, and a crash can leave tables needing repair. "
                    + "InnoDB is the default engine and has neither problem. Converting rebuilds each table.",
                tables: crashProne.map(\.name),
                sql: crashProne.map { "ALTER TABLE \(SQLQuote.qualified(database, $0.name)) ENGINE=InnoDB;" }.joined(separator: "\n")))
        }

        let report = CollationReport(database: database, defaultCharset: input.overview.charset,
                                     defaultCollation: input.overview.collation, columns: input.columns, tables: tables)
        let mb3Columns = input.columns.filter { Charsets.isUTF8MB3($0.charset) }
        if report.usesUTF8MB3 {
            let what = mb3Columns.isEmpty ? "The database or table defaults use utf8mb3"
                : "\(DatabaseOverview.plural(mb3Columns.count, "column")) \(mb3Columns.count == 1 ? "uses" : "use") utf8mb3"
            findings.append(Finding(
                id: "utf8mb3", severity: .warning, title: what,
                detail: "utf8mb3 (also called utf8) can't store emoji or some Chinese, Japanese and Korean characters, "
                    + "and MySQL has deprecated it. Converting to utf8mb4 keeps the same sorting rules.",
                tables: report.tablesToConvert.map(\.table), sql: report.conversionSQL))
        }

        let legacy = input.columns.filter { !Charsets.isUTF8MB3($0.charset) && !Charsets.isFullUnicode($0.charset) }
        if !legacy.isEmpty {
            let names = Set(legacy.map(\.charset)).sorted().joined(separator: ", ")
            findings.append(Finding(
                id: "legacy-charset", severity: .info,
                title: "\(DatabaseOverview.plural(legacy.count, "column")) \(legacy.count == 1 ? "uses" : "use") \(names)",
                detail: "These character sets hold only some languages. Text from other languages is stored as question marks.",
                tables: Array(Set(legacy.map(\.table))).sorted()))
        }

        let collations = Set(input.columns.map(\.collation))
        if collations.count > 1 {
            findings.append(Finding(
                id: "mixed-collations", severity: .info,
                title: "Text columns use \(collations.count) different collations",
                detail: "Comparing or joining columns with different collations can fail with "
                    + "\u{201C}Illegal mix of collations\u{201D}, or skip an index. Find Collations lists them."))
        }

        let fragmented = tables.filter {
            $0.freeBytes > fragmentedBytes && Double($0.freeBytes) > fragmentedShare * Double($0.dataBytes + $0.indexBytes)
        }
        if !fragmented.isEmpty {
            let free = ByteCount.format(fragmented.reduce(0) { $0 + $1.freeBytes })
            findings.append(Finding(
                id: "fragmented", severity: .info,
                title: "\(DatabaseOverview.plural(fragmented.count, "table")) \(fragmented.count == 1 ? "has" : "have") \(free) of unused space",
                detail: "OPTIMIZE TABLE rebuilds a table to give the space back. It locks each table while it runs, "
                    + "so run it when the database is quiet.",
                tables: fragmented.map(\.name),
                sql: "OPTIMIZE TABLE " + fragmented.map { SQLQuote.qualified(database, $0.name) }.joined(separator: ", ") + ";"))
        }

        for column in input.autoIncrements {
            guard let used = column.used, used > autoIncrementShare else { continue }
            let type = column.type.prefix { $0.isLetter }.uppercased()
            findings.append(Finding(
                id: "auto-increment:\(column.table).\(column.column)", severity: used > 0.95 ? .error : .warning,
                title: "\(column.table).\(column.column) has used \(Int(used * 100))% of its \(type) range",
                detail: "Inserts fail once it runs out. Change the column to BIGINT, keeping its other attributes, "
                    + "and change any foreign-key columns that refer to it.",
                tables: [column.table]))
        }

        if findings.isEmpty {
            findings.append(Finding(id: "ok", severity: .ok, title: "No problems found",
                                    detail: tables.isEmpty ? "The database has no tables yet."
                                        : "Checked \(DatabaseOverview.plural(tables.count, "table")) for keys, engines, character sets, "
                                            + "unused space and auto-increment range."))
        }
        return findings.enumerated().sorted { ($1.element.severity, $0.offset) < ($0.element.severity, $1.offset) }.map(\.element)
    }
}
