import Foundation

/// Finds the parts of SQL text to color in the editor. Ranges are UTF-16.
public enum SQLHighlighter {
    public enum Kind: Sendable, Equatable { case keyword, string, number, comment, identifier, variable }

    public struct Token: Sendable, Equatable {
        public var kind: Kind
        public var range: NSRange
    }

    public static let keywords: Set<String> = [
        "ADD", "ALL", "ALTER", "ANALYZE", "AND", "AS", "ASC", "AUTO_INCREMENT", "BEFORE", "AFTER", "BEGIN", "BETWEEN",
        "BIGINT", "BINARY", "BLOB", "BOTH", "BY", "CALL", "CASCADE", "CASE", "CHANGE", "CHAR", "CHARACTER", "CHECK",
        "COLLATE", "COLUMN", "COLUMNS", "COMMENT", "COMMIT", "CONSTRAINT", "CREATE", "CROSS", "CURRENT_TIMESTAMP",
        "DATABASE", "DATABASES", "DATE", "DATETIME", "DECIMAL", "DECLARE", "DEFAULT", "DELETE", "DELIMITER", "DESC",
        "DESCRIBE", "DETERMINISTIC", "DISTINCT", "DIV", "DO", "DOUBLE", "DROP", "EACH", "ELSE", "ELSEIF", "END", "ENGINE",
        "ENUM", "EXISTS", "EXPLAIN", "FALSE", "FLOAT", "FOR", "FOREIGN", "FROM", "FULL", "FULLTEXT", "FUNCTION", "GRANT",
        "GROUP", "HAVING", "IF", "IGNORE", "IN", "INDEX", "INNER", "INSERT", "INT", "INTEGER", "INTERVAL", "INTO", "IS",
        "JOIN", "JSON", "KEY", "KEYS", "KILL", "LEFT", "LIKE", "LIMIT", "LOCK", "LONGTEXT", "MEDIUMTEXT", "MOD", "MODIFY",
        "NOT", "NULL", "OFFSET", "ON", "OR", "ORDER", "OUTER", "PRIMARY", "PROCEDURE", "REFERENCES", "REGEXP", "RENAME",
        "REPLACE", "RESTRICT", "RETURN", "RETURNS", "REVOKE", "RIGHT", "ROLLBACK", "ROW", "SCHEMA", "SELECT", "SET", "SHOW",
        "SMALLINT", "START", "STATUS", "TABLE", "TABLES", "TEMPORARY", "TEXT", "THEN", "TIME", "TIMESTAMP", "TINYINT",
        "TO", "TRANSACTION", "TRIGGER", "TRIGGERS", "TRUE", "TRUNCATE", "UNION", "UNIQUE", "UNLOCK", "UNSIGNED",
        "UPDATE", "USE", "USING", "VALUES", "VARCHAR", "VARIABLES", "VIEW", "WHEN", "WHERE", "WHILE", "WITH", "XOR",
        "ZEROFILL", "COUNT", "SUM", "AVG", "MIN", "MAX", "CONCAT", "COALESCE", "IFNULL", "NOW",
    ]

    public static func tokens(in sql: String) -> [Token] {
        let units = Array(sql.utf16)
        let count = units.count
        var tokens: [Token] = []
        var index = 0

        func add(_ kind: Kind, _ start: Int, _ end: Int) {
            tokens.append(Token(kind: kind, range: NSRange(location: start, length: end - start)))
        }
        func isWordUnit(_ unit: UInt16) -> Bool {
            (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit > 127
        }

        while index < count {
            let unit = units[index]
            let start = index
            switch unit {
            case 39, 34, 96: // quotes and backticks
                var k = index + 1
                while k < count {
                    if units[k] == 92 && unit != 96 { k += 2; continue }
                    if units[k] == unit {
                        if k + 1 < count, units[k + 1] == unit { k += 2; continue }
                        k += 1
                        break
                    }
                    k += 1
                }
                index = min(k, count)
                add(unit == 96 ? .identifier : .string, start, index)
            case 35: // #
                while index < count, units[index] != 10 { index += 1 }
                add(.comment, start, index)
            case 45 where index + 1 < count && units[index + 1] == 45:
                while index < count, units[index] != 10 { index += 1 }
                add(.comment, start, index)
            case 47 where index + 1 < count && units[index + 1] == 42:
                index += 2
                while index < count, !(units[index] == 42 && index + 1 < count && units[index + 1] == 47) { index += 1 }
                index = min(count, index + 2)
                add(.comment, start, index)
            case 64: // @variable or @@system
                index += 1
                while index < count, isWordUnit(units[index]) || units[index] == 64 || units[index] == 46 { index += 1 }
                add(.variable, start, index)
            case 48...57:
                // A number only when it does not continue a word (t1, x2).
                if start > 0, isWordUnit(units[start - 1]) { index += 1; continue }
                while index < count, (units[index] >= 48 && units[index] <= 57) || units[index] == 46
                    || units[index] == 120 || units[index] == 88 || (units[index] >= 97 && units[index] <= 102)
                    || (units[index] >= 65 && units[index] <= 70) { index += 1 }
                if index < count, isWordUnit(units[index]) { continue } // like 1st_col
                add(.number, start, index)
            default:
                if isWordUnit(unit) {
                    while index < count, isWordUnit(units[index]) { index += 1 }
                    let word = String(utf16CodeUnits: Array(units[start..<index]), count: index - start).uppercased()
                    if keywords.contains(word) { add(.keyword, start, index) }
                } else {
                    index += 1
                }
            }
        }
        return tokens
    }
}
