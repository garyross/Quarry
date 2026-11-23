import Foundation

/// The parts of a SQL export of a SQLite file (S-071), in the shape of
/// `sqlite3`'s .dump, which reads it back: no session settings, each table's
/// CREATE from `sqlite_schema`, its rows, its indexes and triggers, and where
/// its AUTOINCREMENT numbering stands in `sqlite_sequence`.
extension SQLDump {
    public enum SQLite {
        /// Comments, then foreign keys off so rows load in any table order.
        /// The PRAGMA does nothing inside a transaction, so it comes first.
        public static func header(file: String, version: String, date: Date) -> String {
            let time = date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false)
                .timeSeparator(.colon))
            return """
            -- Quarry SQL dump
            --
            -- File: \(file) (\(version))
            -- Generation time: \(time)
            -- ------------------------------------------------------------

            PRAGMA foreign_keys = OFF;


            """
        }

        public static let footer = "\n"

        /// "SELECT quote(`a`) AS `a`, …": each value as the SQL that stores it
        /// again exactly (integers bare, reals in full, text quoted, BLOBs as X'…').
        public static func select(columns: [String], table: String, database: String, orderBy keys: [String]) -> String {
            var sql = "SELECT " + columns.map { "quote(\(SQLQuote.identifier($0))) AS \(SQLQuote.identifier($0))" }
                .joined(separator: ", ") + " FROM " + SQLQuote.qualified(database, table)
            if !keys.isEmpty { sql += " ORDER BY " + keys.map(SQLQuote.identifier).joined(separator: ", ") }
            return sql
        }

        /// CREATE INDEX and CREATE TRIGGER statements, as `sqlite_schema` holds them, after the rows.
        public static func statements(_ statements: [String]) -> String {
            statements.map { trimmed($0) + ";\n" }.joined() + (statements.isEmpty ? "" : "\n")
        }

        /// The table's next AUTOINCREMENT number, so new rows continue it.
        public static func sequence(table: String, value: String) -> String {
            let name = SQLQuote.literal(table, engine: .sqlite)
            return "DELETE FROM sqlite_sequence WHERE name = \(name);\n"
                + "INSERT INTO sqlite_sequence (name, seq) VALUES (\(name), \(value));\n\n"
        }

        /// Views in an order where each comes after the views it reads from.
        /// SQLite views name other views in any quoting, or none, so a bare
        /// name counts as well as a quoted one.
        public static func viewOrder(_ statements: [String: String]) -> [String] {
            let names = statements.keys.sorted { $0.lowercased() < $1.lowercased() }
            var done: [String] = []
            var visiting: Set<String> = []
            func mentions(_ body: String, _ name: String) -> Bool {
                let pattern = "(?<![A-Za-z0-9_$])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9_$])"
                return body.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
            func visit(_ name: String) {
                guard !done.contains(name), !visiting.contains(name) else { return }
                visiting.insert(name)
                // A view's own CREATE names itself; only the part after AS reads others.
                let body = statements[name] ?? ""
                let reads = body.range(of: "\\bAS\\b", options: [.regularExpression, .caseInsensitive])
                    .map { String(body[$0.upperBound...]) } ?? body
                for other in names where other != name && mentions(reads, other) { visit(other) }
                visiting.remove(name)
                done.append(name)
            }
            names.forEach(visit)
            return done
        }
    }
}
