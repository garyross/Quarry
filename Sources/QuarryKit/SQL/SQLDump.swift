import Foundation

/// The text of a SQL export (S-041), in the shape of Sequel Pro's and
/// mysqldump's: a header that sets the session up, each table's structure and
/// rows, triggers, views, routines, and a footer that puts the session back.
/// Pure text from plain values, so the escaping and batching are unit tested.
public enum SQLDump {
    /// When a new INSERT statement starts.
    public enum Batch: Sendable, Hashable {
        /// After this many rows.
        case rows(Int)
        /// Before a statement grows past this many KB.
        case kilobytes(Int)

        /// Sequel Pro's default.
        public static let standard = Batch.kilobytes(250)
    }

    public enum Compression: String, Sendable, Hashable, CaseIterable {
        case none, gzip

        public var fileExtension: String { self == .gzip ? "sql.gz" : "sql" }
    }

    public struct Options: Sendable, Hashable {
        /// Keep AUTO_INCREMENT=n in CREATE TABLE, so new rows continue the numbering.
        public var autoIncrement = true
        public var batch = Batch.standard
        /// Every value of a binary column as X'…', even when it reads as text.
        public var hexBlobs = true
        public var compression = Compression.none

        public init(autoIncrement: Bool = true, batch: Batch = .standard, hexBlobs: Bool = true,
                    compression: Compression = .none) {
            self.autoIncrement = autoIncrement
            self.batch = batch
            self.hexBlobs = hexBlobs
            self.compression = compression
        }
    }

    /// What to write for one object: Sequel Pro's S, C and D columns.
    public struct Part: Sendable, Hashable {
        public var structure: Bool
        public var content: Bool
        public var drop: Bool

        public init(structure: Bool = true, content: Bool = true, drop: Bool = true) {
            self.structure = structure
            self.content = content
            self.drop = drop
        }

        public var isEmpty: Bool { !structure && !content && !drop }
    }

    // MARK: Header and footer

    public static func header(server: String, host: String, database: String, date: Date) -> String {
        let time = date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false)
            .timeSeparator(.colon))
        return """
        -- Quarry SQL dump
        --
        -- Host: \(host) (\(server))
        -- Database: \(database)
        -- Generation time: \(time)
        -- ------------------------------------------------------------

        /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
        /*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
        /*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
        SET NAMES utf8mb4;
        /*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
        /*!40103 SET TIME_ZONE='+00:00' */;
        /*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
        /*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
        /*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;


        """
    }

    public static let footer = """

    /*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;
    /*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
    /*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
    /*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;
    /*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
    /*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
    /*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;

    """

    // MARK: Objects

    /// A definition with "`database`." taken out, so the file loads into any
    /// database: views always name their tables that way (`DatabaseTransfer.retarget`).
    public static func unqualified(_ sql: String, database: String) -> String {
        sql.replacingOccurrences(of: SQLQuote.identifier(database) + ".", with: "")
    }

    /// "-- Dump of table orders" and a rule under it.
    public static func section(_ kind: ObjectKind, _ name: String) -> String {
        "\n-- Dump of \(CreateScript.noun(kind)) \(name)\n-- ------------------------------------------------------------\n\n"
    }

    /// DROP and CREATE for a table or view. Without `autoIncrement`, the table's
    /// AUTO_INCREMENT=n goes, so an import starts numbering where its rows end.
    public static func structure(_ object: DBObject, createStatement: String, part: Part, options: Options) -> String {
        var text = ""
        let keyword = object.kind == .view ? "VIEW" : "TABLE"
        if part.drop { text += "DROP \(keyword) IF EXISTS \(SQLQuote.identifier(object.name));\n\n" }
        guard part.structure else { return text }
        var statement = trimmed(createStatement)
        if object.kind == .table, !options.autoIncrement {
            statement = DatabaseTransfer.withoutAutoIncrement(statement)
        }
        return text + statement + ";\n\n"
    }

    /// A procedure or function between DELIMITER ;; lines, as Sequel Pro wrote them.
    public static func routine(_ object: DBObject, createStatement: String, part: Part) -> String {
        var text = "DELIMITER ;;\n"
        if part.drop {
            text += "DROP \(object.kind == .function ? "FUNCTION" : "PROCEDURE") IF EXISTS \(SQLQuote.identifier(object.name));;\n"
        }
        if part.structure { text += trimmed(createStatement) + ";;\n" }
        return text + "DELIMITER ;\n\n"
    }

    /// A table's triggers, from SHOW CREATE TRIGGER, after its rows so the
    /// import doesn't fire them.
    public static func triggers(_ statements: [String]) -> String {
        guard !statements.isEmpty else { return "" }
        return "DELIMITER ;;\n" + statements.map { trimmed($0) + ";;\n" }.joined() + "DELIMITER ;\n\n"
    }

    /// Views in an order where each comes after the views it reads from.
    /// `statements` maps each view's name to its CREATE VIEW.
    public static func viewOrder(_ statements: [String: String]) -> [String] {
        let names = statements.keys.sorted { $0.lowercased() < $1.lowercased() }
        var done: [String] = []
        var visiting: Set<String> = []
        func visit(_ name: String) {
            guard !done.contains(name), !visiting.contains(name) else { return }
            visiting.insert(name)
            let body = statements[name] ?? ""
            for other in names where other != name && body.contains(SQLQuote.identifier(other)) { visit(other) }
            visiting.remove(name)
            done.append(name)
        }
        names.forEach(visit)
        return done
    }

    /// LOCK TABLES and DISABLE KEYS around a table's rows, as mysqldump does, so they load fast.
    public static func rowsStart(_ table: String) -> String {
        let name = SQLQuote.identifier(table)
        return "LOCK TABLES \(name) WRITE;\n/*!40000 ALTER TABLE \(name) DISABLE KEYS */;\n\n"
    }

    public static func rowsEnd(_ table: String) -> String {
        let name = SQLQuote.identifier(table)
        return "/*!40000 ALTER TABLE \(name) ENABLE KEYS */;\nUNLOCK TABLES;\n\n"
    }

    // MARK: Values

    /// One value as SQL: NULL; numbers bare; BIT as b'0101'; binary as X'…'
    /// (bytes that aren't text always are, so the file stays UTF-8); text quoted and escaped.
    public static func literal(_ value: CellValue, column: ResultColumn, hexBlobs: Bool) -> String {
        switch value {
        case .null:
            return "NULL"
        case .flag(let on):
            return on ? "1" : "0"
        case .binary(let data):
            if let width = column.bitWidth { return "b'" + BitValue(width: width, data: data).bits + "'" }
            return hex(data)
        case .text(let text):
            if column.isNumeric, isNumber(text) { return text }
            if column.isBinary, hexBlobs { return hex(Data(text.utf8)) }
            return SQLQuote.mysqlLiteral(text)
        }
    }

    static func hex(_ data: Data) -> String {
        data.isEmpty ? "''" : "X'" + data.map { String(format: "%02X", $0) }.joined() + "'"
    }

    /// Digits, sign, point and exponent only: anything else is quoted.
    static func isNumber(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isNumber || "+-.eE".contains($0)) }
    }

    static func trimmed(_ statement: String) -> String {
        var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") { text.removeLast(); text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return text
    }

    // MARK: INSERT batching

    /// Writes a table's rows as multi-row INSERTs, starting a new statement
    /// after `batch` rows or before one passes `batch` KB. Feed it rows page by page.
    public struct Inserts: Sendable {
        public let table: String
        public let columns: [ResultColumn]
        public let batch: Batch
        public let hexBlobs: Bool
        /// Each value is already SQL, as SQLite's quote() writes it (S-071).
        public let literals: Bool
        private var rowsInStatement = 0
        private var bytesInStatement = 0

        public init(table: String, columns: [ResultColumn], batch: Batch, hexBlobs: Bool, literals: Bool = false) {
            self.table = table
            self.columns = columns
            self.batch = batch
            self.hexBlobs = hexBlobs
            self.literals = literals
        }

        private func sql(_ value: CellValue, _ column: ResultColumn) -> String {
            guard literals else { return literal(value, column: column, hexBlobs: hexBlobs) }
            switch value {
            case .text(let text): return text
            case .binary(let data): return String(decoding: data, as: UTF8.self)
            case .null: return "NULL"
            case .flag(let on): return on ? "1" : "0"
            }
        }

        private var opening: String {
            "INSERT INTO \(SQLQuote.identifier(table)) (\(columns.map { SQLQuote.identifier($0.name) }.joined(separator: ", ")))\nVALUES\n"
        }

        /// The text that adds these rows to the file.
        public mutating func append(_ rows: [[CellValue]]) -> String {
            var out = ""
            for row in rows {
                let tuple = "\t(" + zip(row, columns).map { sql($0, $1) }
                    .joined(separator: ", ") + ")"
                let size = tuple.utf8.count + 2
                if rowsInStatement > 0, isFull(adding: size) {
                    out += ";\n\n"
                    rowsInStatement = 0
                    bytesInStatement = 0
                }
                if rowsInStatement == 0 {
                    out += opening
                    bytesInStatement = opening.utf8.count
                } else {
                    out += ",\n"
                }
                out += tuple
                rowsInStatement += 1
                bytesInStatement += size
            }
            return out
        }

        /// Ends the last statement; empty when no rows came.
        public mutating func finish() -> String {
            guard rowsInStatement > 0 else { return "" }
            rowsInStatement = 0
            bytesInStatement = 0
            return ";\n\n"
        }

        private func isFull(adding size: Int) -> Bool {
            switch batch {
            case .rows(let limit): rowsInStatement >= max(1, limit)
            case .kilobytes(let limit): bytesInStatement + size > max(1, limit) * 1024
            }
        }
    }
}
