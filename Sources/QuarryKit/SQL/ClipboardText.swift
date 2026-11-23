import Foundation

/// Text on the clipboard to import (S-046): whether it reads as SQL or as
/// delimited rows, and the lines the Import sheet previews.
public enum ClipboardText {
    public enum Kind: Equatable, Sendable {
        case sql
        /// Delimited rows, with the field separator: a tab for cells copied
        /// from a spreadsheet.
        case csv(separator: String)
    }

    /// Words a SQL statement starts with.
    static let statementWords: Set<String> = [
        "ALTER", "ANALYZE", "BEGIN", "CALL", "CHECK", "COMMIT", "CREATE", "DELETE", "DELIMITER", "DO", "DROP",
        "EXPLAIN", "FLUSH", "GRANT", "INSERT", "LOAD", "LOCK", "OPTIMIZE", "RENAME", "REPAIR", "REPLACE", "REVOKE",
        "ROLLBACK", "SELECT", "SET", "SHOW", "START", "TRUNCATE", "UNLOCK", "UPDATE", "USE", "WITH",
    ]

    /// SQL when the first line that isn't blank starts with a statement word
    /// or a comment; a tab in that line means spreadsheet cells; otherwise
    /// the separator the line holds most of (comma when it holds none).
    public static func guess(_ text: String) -> Kind {
        guard let line = text.split(whereSeparator: \.isNewline)
            .first(where: { !$0.allSatisfy(\.isWhitespace) }) else { return .csv(separator: ",") }
        let trimmed = line.drop(while: \.isWhitespace)
        if trimmed.hasPrefix("--") || trimmed.hasPrefix("#") || trimmed.hasPrefix("/*") { return .sql }
        if line.contains("\t") { return .csv(separator: "\t") }
        let word = trimmed.prefix(while: { $0.isLetter }).uppercased()
        // "Update,Price" is a header row; "UPDATE t SET …" and "COMMIT;" are statements.
        let rest = trimmed.dropFirst(word.count)
        let ends = rest.first == ";" && rest.dropFirst().allSatisfy(\.isWhitespace)
        if statementWords.contains(word), rest.first.map({ $0.isWhitespace || $0 == "(" }) ?? true || ends {
            return .sql
        }
        let counts = [",", ";", "|"].map { separator in (separator, line.filter { String($0) == separator }.count) }
        let best = counts.max { $0.1 < $1.1 }!
        return .csv(separator: best.1 > 0 ? best.0 : ",")
    }

    /// The first `lines` lines, each cut at `width` characters, with "…"
    /// when there is more.
    /// Tab-separated cells line up in columns, each padded to its widest
    /// cell (up to `cell` characters) plus two spaces.
    public static func preview(_ text: String, lines: Int = 6, width: Int = 120, cell: Int = 24) -> String {
        let all = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var head = all.prefix(lines).map(String.init)
        if head.contains(where: { $0.contains("\t") }) {
            let rows = head.map { $0.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.count > cell ? $0.prefix(cell - 1) + "…" : String($0) } }
            var widths: [Int] = []
            for row in rows {
                for (index, value) in row.enumerated() {
                    if index == widths.count { widths.append(0) }
                    widths[index] = max(widths[index], value.count)
                }
            }
            head = rows.map { row in
                row.enumerated().map { index, value in
                    index == row.count - 1 ? value : value.padding(toLength: widths[index] + 2, withPad: " ", startingAt: 0)
                }.joined()
            }
        }
        var shown = head.map { $0.count > width ? $0.prefix(width) + "…" : $0 }
        while shown.last?.isEmpty == true { shown.removeLast() }
        let rest = all.dropFirst(lines).contains { !$0.isEmpty }
        return shown.joined(separator: "\n") + (rest ? "\n…" : "")
    }

    /// "12 lines, 1 KB".
    public static func summary(_ text: String) -> String {
        let count = text.split(whereSeparator: \.isNewline).count
        let size = ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
        return "\(count.formatted()) line\(count == 1 ? "" : "s"), \(size)"
    }
}
