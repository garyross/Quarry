import Foundation

/// The SQL rules for agents (S-063): which statements count as reads, and
/// `?` placeholders filled with quoted values.
///
/// A read runs inside START TRANSACTION READ ONLY, so the server itself
/// refuses writes to tables, also from inside stored functions. These text
/// checks cover what that does not: statements that commit on their own
/// (DDL), files (INTO OUTFILE, LOAD_FILE), locks, and stacked statements.
///
/// On a SQLite file (S-073) reads run on a connection opened read only with
/// `PRAGMA query_only`, so SQLite refuses every write itself; these rules add
/// PRAGMAs that only read, and refuse ATTACH, `load_extension` and VACUUM INTO.
public enum AgentSQL {
    /// The statements a read may start with.
    public static let readKeywords: Set<String> = ["SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "WITH", "VALUES", "TABLE", "HELP"]
    /// The statements a read may start with on a SQLite file.
    public static let sqliteReadKeywords: Set<String> = ["SELECT", "EXPLAIN", "WITH", "VALUES", "PRAGMA"]

    /// SQLite PRAGMAs that take an argument and only read: `PRAGMA table_info(orders)`.
    public static let sqliteReadingPragmas: Set<String> = [
        "TABLE_INFO", "TABLE_XINFO", "TABLE_LIST", "INDEX_LIST", "INDEX_INFO", "INDEX_XINFO", "FOREIGN_KEY_LIST",
        "FOREIGN_KEY_CHECK", "INTEGRITY_CHECK", "QUICK_CHECK",
    ]
    /// SQLite PRAGMAs that read a setting when given no value: `PRAGMA journal_mode`.
    public static let sqliteSettingPragmas: Set<String> = Set([
        "APPLICATION_ID", "AUTO_VACUUM", "AUTOMATIC_INDEX", "BUSY_TIMEOUT", "CACHE_SIZE", "CACHE_SPILL", "CASE_SENSITIVE_LIKE",
        "CELL_SIZE_CHECK", "CHECKPOINT_FULLFSYNC", "COLLATION_LIST", "COMPILE_OPTIONS", "DATA_VERSION", "DATABASE_LIST",
        "DEFER_FOREIGN_KEYS", "ENCODING", "FOREIGN_KEYS", "FREELIST_COUNT", "FULLFSYNC", "FUNCTION_LIST", "HARD_HEAP_LIMIT",
        "IGNORE_CHECK_CONSTRAINTS", "JOURNAL_MODE", "JOURNAL_SIZE_LIMIT", "LEGACY_ALTER_TABLE", "LOCKING_MODE",
        "MAX_PAGE_COUNT", "MMAP_SIZE", "MODULE_LIST", "PAGE_COUNT", "PAGE_SIZE", "PRAGMA_LIST", "QUERY_ONLY",
        "READ_UNCOMMITTED", "RECURSIVE_TRIGGERS", "REVERSE_UNORDERED_SELECTS", "SCHEMA_VERSION", "SECURE_DELETE",
        "SOFT_HEAP_LIMIT", "SYNCHRONOUS", "TEMP_STORE", "THREADS", "TRUSTED_SCHEMA", "USER_VERSION", "WAL_AUTOCHECKPOINT",
    ]).union(sqliteReadingPragmas)

    /// What read_query and write_query say about ATTACH on a SQLite file (S-073).
    public static let attachProblem = "ATTACH isn’t allowed. Ask the person to save the other file as its own connection."

    /// Why `sql` is not a read an agent may run, or nil when it is one.
    public static func readProblem(_ sql: String, engine: Engine) -> String? {
        let scan = Scan(sql, backslashEscapes: engine == .mysql)
        if let problem = scan.problem ?? stackProblem(sql, scan: scan, engine: engine) { return problem }
        let words = scan.words
        guard let first = words.first else { return "The SQL is empty." }
        if engine == .sqlite { return sqliteReadProblem(scan, first: first) }
        guard readKeywords.contains(first) else {
            return "read_query runs only SELECT, SHOW, DESCRIBE, EXPLAIN, WITH, VALUES and TABLE statements; "
                + "\(first) changes something. Use write_query for it."
        }
        if first == "EXPLAIN", words.dropFirst().first == "ANALYZE" {
            return "EXPLAIN ANALYZE runs the statement. Use explain_query, or EXPLAIN without ANALYZE."
        }
        if scan.has(["INTO", "OUTFILE"]) || scan.has(["INTO", "DUMPFILE"]) {
            return "INTO OUTFILE and INTO DUMPFILE write files on the server, so a read can't use them."
        }
        if scan.calls("LOAD_FILE") {
            return "LOAD_FILE reads files on the server, so a read can't use it."
        }
        if scan.has(["FOR", "UPDATE"]) || scan.has(["FOR", "SHARE"]) || scan.has(["LOCK", "IN", "SHARE", "MODE"]) {
            return "Locking reads (FOR UPDATE, FOR SHARE, LOCK IN SHARE MODE) hold rows other connections need. Leave the lock out."
        }
        return nil
    }

    /// Why `sql` can't run as one statement through write_query, or nil.
    public static func statementProblem(_ sql: String, engine: Engine) -> String? {
        let scan = Scan(sql, backslashEscapes: engine == .mysql)
        if let problem = scan.problem ?? stackProblem(sql, scan: scan, engine: engine) { return problem }
        guard let first = scan.words.first else { return "The SQL is empty." }
        if engine == .sqlite { return sqliteFileProblem(scan, first: first) }
        return nil
    }

    /// The statement's first keyword, uppercased ("SELECT"); nil when there is none.
    public static func firstKeyword(_ sql: String) -> String? { Scan(sql).words.first }

    // MARK: SQLite (S-073)

    /// What no agent statement on a SQLite file may do: reach other files.
    private static func sqliteFileProblem(_ scan: Scan, first: String) -> String? {
        if first == "ATTACH" || first == "DETACH" { return attachProblem }
        if scan.calls("LOAD_EXTENSION") { return "load_extension isn’t allowed: it runs code from a file." }
        if first == "VACUUM", scan.words.contains("INTO") {
            return "VACUUM INTO writes a new file, so agents can’t use it."
        }
        if first == "PRAGMA", scan.words.dropFirst().contains("WRITABLE_SCHEMA") {
            return "PRAGMA writable_schema can damage the file, so agents can’t use it."
        }
        return nil
    }

    private static func sqliteReadProblem(_ scan: Scan, first: String) -> String? {
        if let problem = sqliteFileProblem(scan, first: first) { return problem }
        guard sqliteReadKeywords.contains(first) else {
            return "read_query runs only SELECT, WITH, VALUES, EXPLAIN and PRAGMAs that read; "
                + "\(first) changes something. Use write_query for it."
        }
        guard first == "PRAGMA" else { return nil }
        // PRAGMA [schema.]name [= value | (argument)]
        var rest = Array(scan.tokens.drop { $0 != "PRAGMA" }.dropFirst())
        if rest.count >= 3, rest[1] == "." { rest.removeFirst(2) }
        guard let name = rest.first else { return "Name the PRAGMA to read." }
        let display = "PRAGMA " + name.lowercased()
        if rest.contains("=") { return "\(display) = … changes a setting. Use write_query for it." }
        let argument = rest.dropFirst().first == "("
        if argument ? sqliteReadingPragmas.contains(name) : sqliteSettingPragmas.contains(name) { return nil }
        if argument, sqliteSettingPragmas.contains(name) {
            return "\(display)(…) changes a setting. Leave out the value to read it, or use write_query."
        }
        return "\(display) may change the file, so read_query doesn’t run it. Use write_query for it."
    }

    private static func stackProblem(_ sql: String, scan: Scan, engine: Engine) -> String? {
        // StatementSplitter reads quotes as MySQL does; SQLite's have no backslash escapes, so count the scan's semicolons.
        let count = engine == .sqlite ? scan.tokens.split(separator: ";").count : StatementSplitter.split(sql).count
        return count > 1 ? "Send one statement at a time; this SQL has \(count)." : nil
    }

    // MARK: Placeholders

    public struct BindError: Error, Equatable, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// `sql` with each `?` outside quotes and comments replaced by the next
    /// value, quoted: strings as literals, numbers and booleans as they are,
    /// null as NULL. Quotes and placeholders follow `engine`'s rules: SQLite text
    /// has no backslash escapes.
    public static func bind(_ sql: String, _ params: [JSONValue], engine: Engine) throws -> String {
        let marks = Scan(sql, backslashEscapes: engine == .mysql).placeholders
        guard marks.count == params.count else {
            throw BindError(message: "The SQL has \(marks.count) ? placeholder\(marks.count == 1 ? "" : "s") "
                + "but params has \(params.count) value\(params.count == 1 ? "" : "s").")
        }
        guard !marks.isEmpty else { return sql }
        var scalars = Array(sql.unicodeScalars)
        for (offset, value) in zip(marks, params).reversed() {
            scalars.replaceSubrange(offset...offset, with: try literal(value, engine: engine).unicodeScalars)
        }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }

    static func literal(_ value: JSONValue, engine: Engine) throws -> String {
        switch value {
        case .null: return "NULL"
        case .bool(let flag): return flag ? "TRUE" : "FALSE"
        case .int(let number): return String(number)
        case .double(let number):
            guard number.isFinite else { throw BindError(message: "params can't hold infinity or NaN.") }
            return String(number)
        case .string(let text): return SQLQuote.literal(text, engine: engine)
        case .array, .object: throw BindError(message: "params holds strings, numbers, booleans and null, not lists or objects.")
        }
    }

    // MARK: Scanning

    /// The SQL as words, symbols and placeholders, with quoted text and comments set aside.
    struct Scan {
        /// Uppercased words and single-character symbols outside quotes and comments;
        /// a quoted string or name is one "'" or "`" token.
        var tokens: [String] = []
        /// Offsets of `?` placeholders in the SQL's unicode scalars.
        var placeholders: [Int] = []
        var problem: String?

        var words: [String] {
            tokens.drop { $0 == "(" }.filter { $0.first?.isLetter == true || $0.first == "_" }.map { $0 }
        }

        /// True when `sequence` appears as consecutive tokens.
        func has(_ sequence: [String]) -> Bool {
            guard sequence.count <= tokens.count else { return false }
            for start in 0...(tokens.count - sequence.count) where Array(tokens[start..<start + sequence.count]) == sequence {
                return true
            }
            return false
        }

        /// True when `function` is called: its name, then "(".
        func calls(_ function: String) -> Bool { has([function, "("]) }

        /// With `backslashEscapes` off (SQLite), a backslash inside quotes is an ordinary character.
        init(_ sql: String, backslashEscapes: Bool = true) {
            let s = Array(sql.unicodeScalars)
            var i = 0
            func isWord(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic || c.properties.numericType != nil || c == "_" || c == "$" }
            while i < s.count {
                let c = s[i]
                let next: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil
                if c == "'" || c == "\"" || c == "`" {
                    let quote = c
                    i += 1
                    var closed = false
                    while i < s.count {
                        if backslashEscapes, s[i] == "\\", quote != "`" { i += 2; continue }
                        if s[i] == quote {
                            if i + 1 < s.count, s[i + 1] == quote { i += 2; continue }
                            closed = true
                            i += 1
                            break
                        }
                        i += 1
                    }
                    if !closed { problem = problem ?? "The SQL has a quote that is never closed." }
                    tokens.append(quote == "`" ? "`" : "'")
                } else if c == "#" || (c == "-" && next == "-" && (i + 2 >= s.count || s[i + 2].properties.isWhitespace)) {
                    while i < s.count, s[i] != "\n" { i += 1 }
                } else if c == "/" && next == "*" {
                    let mark = i + 2 < s.count ? s[i + 2] : nil
                    if mark == "!" || (mark == "M" && i + 3 < s.count && s[i + 3] == "!") {
                        problem = problem ?? "Executable comments (/*! … */) run as SQL. Write the statement without them."
                    }
                    i += 2
                    while i < s.count, !(s[i] == "*" && i + 1 < s.count && s[i + 1] == "/") { i += 1 }
                    i = min(s.count, i + 2)
                } else if isWord(c) {
                    var word = String.UnicodeScalarView()
                    while i < s.count, isWord(s[i]) { word.append(s[i]); i += 1 }
                    tokens.append(String(word).uppercased())
                } else if c.properties.isWhitespace {
                    i += 1
                } else {
                    if c == "?" { placeholders.append(i) }
                    tokens.append(String(c))
                    i += 1
                }
            }
        }
    }
}
