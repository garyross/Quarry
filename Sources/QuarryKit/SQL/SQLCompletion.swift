import Foundation

/// What the query editor can complete: the server's databases and, per
/// database, its tables and views with their columns (S-031).
public struct CompletionCatalog: Sendable, Equatable {
    public struct Column: Sendable, Equatable {
        public var name: String
        /// The column type as the server shows it ("int(11)", "varchar(255)").
        public var type: String
        public init(name: String, type: String) { self.name = name; self.type = type }
    }

    public struct Table: Sendable, Equatable {
        public var name: String
        public var isView: Bool
        public var columns: [Column]
        public init(name: String, isView: Bool = false, columns: [Column] = []) {
            self.name = name; self.isView = isView; self.columns = columns
        }
    }

    public var databases: [String]
    public var currentDatabase: String?
    /// Tables by database name; a database missing here has not been loaded yet.
    public var tables: [String: [Table]]

    public init(databases: [String] = [], currentDatabase: String? = nil, tables: [String: [Table]] = [:]) {
        self.databases = databases; self.currentDatabase = currentDatabase; self.tables = tables
    }

    func table(_ name: String, in database: String?) -> Table? {
        guard let database = database ?? currentDatabase else { return nil }
        let lowered = name.lowercased()
        return tables[database]?.first { $0.name.lowercased() == lowered }
    }

    func database(named name: String) -> String? {
        let lowered = name.lowercased()
        return databases.first { $0.lowercased() == lowered }
    }
}

/// One entry in the completion list.
public struct Completion: Sendable, Equatable, Hashable {
    public enum Kind: Int, Sendable, Comparable {
        case column, table, view, database, keyword, function
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public var kind: Kind
    public var name: String
    /// Shown dimmed after the name: a column's type and table, "table", "keyword".
    public var detail: String
    /// What replaces the typed word: names are backtick-quoted when they need it,
    /// functions get an opening parenthesis, keywords and tables after FROM a
    /// space (the editor drops it when a space already follows).
    public var insertText: String
}

/// The list for one cursor position, and the typed word it replaces.
public struct CompletionList: Sendable, Equatable {
    public var items: [Completion]
    /// The word before the cursor (UTF-16 range in the editor's text).
    public var replaceRange: NSRange
    /// A database whose tables this position needs but the catalog does not have yet.
    public var needsDatabase: String?
}

/// Works out what fits at the cursor in the query editor (S-031): tables
/// after FROM, JOIN, INTO, UPDATE; a table's columns after `alias.`; a
/// database's tables after `db.`; databases after USE; elsewhere the columns
/// of the statement's tables, then tables, keywords and functions.
public enum SQLCompletion {
    public enum Context: Sendable, Equatable {
        /// Inside a string or comment: nothing to complete.
        case none
        /// Tables and views, of a database or (nil) the current one, plus database names when unqualified.
        case tables(database: String?)
        case databases
        /// The columns of a table named by an alias or name before a dot.
        case columns(table: String, database: String?)
        /// No clause that narrows it: columns in scope, tables, keywords, functions.
        case any
    }

    /// At most this many items, so the list stays quick to draw and to scan.
    public static let limit = 50

    public static let functions: [String] = [
        "ABS", "AVG", "CAST", "CEIL", "CHAR_LENGTH", "COALESCE", "CONCAT", "CONCAT_WS", "CONVERT", "COUNT", "CURDATE",
        "CURRENT_DATE", "CURRENT_TIMESTAMP", "DATE", "DATE_ADD", "DATE_FORMAT", "DATE_SUB", "DATEDIFF", "DAY", "FLOOR",
        "FROM_UNIXTIME", "GREATEST", "GROUP_CONCAT", "HEX", "HOUR", "IF", "IFNULL", "INSTR", "JSON_ARRAY",
        "JSON_EXTRACT", "JSON_OBJECT", "JSON_UNQUOTE", "LAST_INSERT_ID", "LEAST", "LEFT", "LENGTH", "LOCATE", "LOWER",
        "LPAD", "LTRIM", "MAX", "MD5", "MIN", "MONTH", "NOW", "NULLIF", "RAND", "REPLACE", "RIGHT", "ROUND", "RPAD",
        "RTRIM", "SHA2", "SUBSTRING", "SUBSTRING_INDEX", "SUM", "TIMESTAMPDIFF", "TRIM", "UNIX_TIMESTAMP", "UPPER",
        "UUID", "YEAR",
    ]

    /// Keywords before a table name.
    static let tableKeywords: Set<String> = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE", "DESCRIBE", "DESC", "TRUNCATE"]
    /// Words that end a FROM list (so `, x` after them is not a table).
    static let clauseKeywords: Set<String> = [
        "SELECT", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "ON", "USING", "SET", "VALUES", "UNION", "BY",
        "SHOW", "USE", "CALL", "INSERT", "DELETE", "REPLACE", "CREATE", "ALTER", "DROP",
    ]

    // MARK: Entry point

    /// The list at `cursor` in `text`, or nil when there is nothing to offer.
    /// `explicit` is true when the user asked (⌥⎋): an empty word then lists everything that fits.
    public static func complete(_ text: String, cursor: Int, catalog: CompletionCatalog,
                                explicit: Bool = false) -> CompletionList? {
        let ns = text as NSString
        let cursor = max(0, min(cursor, ns.length))
        let word = wordRange(in: ns, before: cursor)
        let prefix = ns.substring(with: word).replacingOccurrences(of: "`", with: "")
        let context = self.context(text, cursor: cursor, catalog: catalog)
        if case .none = context { return nil }
        let afterDot = word.location > 0 && ns.character(at: word.location - 1) == 46
        if prefix.isEmpty, !explicit, !afterDot { return nil }

        var needs: String?
        var candidates: [Completion] = []
        switch context {
        case .none:
            return nil
        case .databases:
            candidates = catalog.databases.map(databaseItem)
        case let .tables(database):
            let db = database ?? catalog.currentDatabase
            if let db, catalog.tables[db] == nil { needs = db }
            // A table here is followed by an alias, a keyword or a comma: add the space.
            candidates = (db.flatMap { catalog.tables[$0] } ?? []).map(tableItem).map { item in
                var item = item
                item.insertText += " "
                return item
            }
            if database == nil { candidates += catalog.databases.map(databaseItem) }
        case let .columns(table, database):
            let db = database ?? catalog.currentDatabase
            if let db, catalog.tables[db] == nil { needs = db }
            if let found = catalog.table(table, in: database) {
                candidates = found.columns.map { columnItem($0, table: found.name) }
            }
        case .any:
            let statement = currentStatement(text, cursor: cursor)
            for reference in tableReferences(in: statement.text) {
                let db = reference.database.flatMap(catalog.database(named:)) ?? catalog.currentDatabase
                if let db, catalog.tables[db] == nil { needs = needs ?? db }
                if let found = catalog.table(reference.table, in: db) {
                    candidates += found.columns.map { columnItem($0, table: found.name) }
                }
            }
            if let db = catalog.currentDatabase {
                if catalog.tables[db] == nil { needs = needs ?? db }
                candidates += (catalog.tables[db] ?? []).map(tableItem)
            }
            candidates += SQLHighlighter.keywords.sorted().map {
                Completion(kind: .keyword, name: $0, detail: "keyword", insertText: $0 + " ")
            }
            candidates += functions.map { Completion(kind: .function, name: $0, detail: "function", insertText: $0 + "(") }
        }
        let items = rank(candidates, prefix: prefix)
        // Nothing new to offer: the word is already complete.
        if items.isEmpty || (items.count == 1 && items[0].name.caseInsensitiveCompare(prefix) == .orderedSame) {
            return needs.map { CompletionList(items: [], replaceRange: word, needsDatabase: $0) }
        }
        return CompletionList(items: items, replaceRange: word, needsDatabase: needs)
    }

    /// Prefix matches first (by kind, then name), then names that contain the word; no duplicates.
    static func rank(_ candidates: [Completion], prefix: String) -> [Completion] {
        let lowered = prefix.lowercased()
        var seen = Set<String>()
        var starts: [Completion] = []
        var contains: [Completion] = []
        for item in candidates {
            let key = "\(item.kind.rawValue)|\(item.name)|\(item.detail)"
            guard !seen.contains(key) else { continue }
            let name = item.name.lowercased()
            if lowered.isEmpty || name.hasPrefix(lowered) {
                seen.insert(key); starts.append(item)
            } else if lowered.count >= 2, name.contains(lowered) {
                seen.insert(key); contains.append(item)
            }
        }
        // Columns keep their table order; the rest sort by name.
        let order: (Completion, Completion) -> Bool = { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            if a.kind == .column { return false }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let sortedStarts = starts.enumerated().sorted { x, y in
            order(x.element, y.element) || (!order(y.element, x.element) && x.offset < y.offset)
        }.map(\.element)
        let sortedContains = contains.enumerated().sorted { x, y in
            order(x.element, y.element) || (!order(y.element, x.element) && x.offset < y.offset)
        }.map(\.element)
        return Array((sortedStarts + sortedContains).prefix(limit))
    }

    // MARK: Context

    /// What fits at `cursor` (see `Context`).
    public static func context(_ text: String, cursor: Int, catalog: CompletionCatalog) -> Context {
        let ns = text as NSString
        let cursor = max(0, min(cursor, ns.length))
        if isInStringOrComment(text, at: cursor) { return .none }
        let statement = currentStatement(text, cursor: cursor)
        let local = cursor - statement.offset
        let word = wordRange(in: statement.text as NSString, before: local)
        let tokens = self.tokens(in: (statement.text as NSString).substring(to: word.location))

        // `qualifier.` right before the word.
        if let last = tokens.last, last == ".", tokens.count >= 2, let qualifier = identifier(tokens[tokens.count - 2]) {
            // `db.table.` → that table's columns.
            if tokens.count >= 4, tokens[tokens.count - 3] == ".", let db = identifier(tokens[tokens.count - 4]) {
                return .columns(table: qualifier, database: catalog.database(named: db) ?? db)
            }
            if (tokens.count >= 3 && startsTableName(tokens, at: tokens.count - 3)) || isInFromList(Array(tokens.dropLast(2))) {
                return .tables(database: catalog.database(named: qualifier) ?? qualifier)
            }
            // An alias or table of this statement wins over a database of the same name.
            if let reference = tableReferences(in: statement.text).first(where: {
                $0.alias?.lowercased() == qualifier.lowercased() || $0.table.lowercased() == qualifier.lowercased()
            }) {
                return .columns(table: reference.table, database: reference.database.flatMap(catalog.database(named:)) ?? reference.database)
            }
            if let db = catalog.database(named: qualifier) { return .tables(database: db) }
            return .columns(table: qualifier, database: nil)
        }
        guard let last = tokens.last else { return .any }
        let upper = last.uppercased()
        if upper == "USE" { return .databases }
        if startsTableName(tokens, at: tokens.count - 1) { return .tables(database: nil) }
        if last == ",", isInFromList(Array(tokens.dropLast())) { return .tables(database: nil) }
        return .any
    }

    /// True when the token at `index` comes right before a table name. DESC and
    /// DESCRIBE count only as the statement's first word (not ORDER BY x DESC).
    static func startsTableName(_ tokens: [String], at index: Int) -> Bool {
        let upper = tokens[index].uppercased()
        guard tableKeywords.contains(upper) else { return false }
        return upper == "DESC" || upper == "DESCRIBE" ? index == 0 : true
    }

    /// True when the tokens end inside a FROM list, so a comma starts another table.
    static func isInFromList(_ tokens: [String]) -> Bool {
        var depth = 0
        for token in tokens.reversed() {
            if token == ")" { depth += 1; continue }
            if token == "(" { if depth == 0 { return false }; depth -= 1; continue }
            guard depth == 0 else { continue }
            let upper = token.uppercased()
            if upper == "FROM" || upper == "JOIN" || upper == "UPDATE" { return true }
            if clauseKeywords.contains(upper) { return false }
        }
        return false
    }

    /// A table the statement reads or writes, with its database and alias when given.
    public struct TableReference: Sendable, Equatable {
        public var database: String?
        public var table: String
        public var alias: String?
    }

    /// The tables after FROM, JOIN, UPDATE and INTO, and in FROM lists, with their aliases.
    public static func tableReferences(in statement: String) -> [TableReference] {
        let tokens = self.tokens(in: statement)
        var references: [TableReference] = []
        var index = 0
        var inFromList = false
        while index < tokens.count {
            let upper = tokens[index].uppercased()
            let startsTable = startsTableName(tokens, at: index) || (inFromList && tokens[index] == ",")
            if upper == "FROM" || upper == "UPDATE" { inFromList = true }
            else if clauseKeywords.contains(upper) || upper == ")" { inFromList = false }
            index += 1
            guard startsTable, index < tokens.count, var name = identifier(tokens[index]) else { continue }
            var database: String?
            index += 1
            if index + 1 < tokens.count, tokens[index] == ".", let table = identifier(tokens[index + 1]) {
                database = name
                name = table
                index += 2
            }
            var alias: String?
            if index < tokens.count, tokens[index].uppercased() == "AS" { index += 1 }
            if index < tokens.count, let word = identifier(tokens[index]), !isReserved(word) {
                alias = word
                index += 1
            }
            references.append(TableReference(database: database, table: name, alias: alias))
        }
        return references
    }

    // MARK: Text helpers

    /// The word that ends at `cursor`: letters, digits, _, $ and backticks.
    static func wordRange(in text: NSString, before cursor: Int) -> NSRange {
        var start = cursor
        while start > 0, isWordUnit(text.character(at: start - 1)) || text.character(at: start - 1) == 96 { start -= 1 }
        return NSRange(location: start, length: cursor - start)
    }

    static func isWordUnit(_ unit: UInt16) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit == 36 || unit > 127
    }

    /// The statement around the cursor, and where it starts in the whole text.
    static func currentStatement(_ text: String, cursor: Int) -> (text: String, offset: Int) {
        let statements = StatementSplitter.split(text)
        guard let statement = StatementSplitter.statement(at: cursor, in: statements) else { return (text, 0) }
        let ns = text as NSString
        // Up to the cursor at least, so the word being typed is inside it.
        let end = max(NSMaxRange(statement.range), cursor)
        return (ns.substring(with: NSRange(location: statement.range.location, length: end - statement.range.location)),
                statement.range.location)
    }

    /// True inside a quoted string or a comment (an unclosed one runs to the end).
    static func isInStringOrComment(_ text: String, at cursor: Int) -> Bool {
        let length = (text as NSString).length
        for token in SQLHighlighter.tokens(in: text) where token.kind == .string || token.kind == .comment {
            let end = NSMaxRange(token.range)
            if cursor > token.range.location, cursor < end { return true }
            // Unclosed at the end of the text, or a line comment up to its newline.
            if cursor == end, end == length || token.kind == .comment, !isClosed(token, in: text) { return true }
        }
        return false
    }

    private static func isClosed(_ token: SQLHighlighter.Token, in text: String) -> Bool {
        let value = (text as NSString).substring(with: token.range)
        if token.kind == .comment { return value.hasPrefix("/*") && value.hasSuffix("*/") && value.count >= 4 }
        guard let quote = value.first, value.count >= 2 else { return false }
        return value.last == quote
    }

    /// Words, quoted names and punctuation, with strings and comments left out.
    static func tokens(in text: String) -> [String] {
        let units = Array(text.utf16)
        var tokens: [String] = []
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == 96 { // `name`
                var end = index + 1
                while end < units.count, units[end] != 96 { end += 1 }
                end = min(end + 1, units.count)
                tokens.append(String(utf16CodeUnits: Array(units[index..<end]), count: end - index))
                index = end
            } else if unit == 39 || unit == 34 { // strings
                var end = index + 1
                while end < units.count, units[end] != unit { if units[end] == 92 { end += 1 }; end += 1 }
                index = min(end + 1, units.count)
                tokens.append("''")
            } else if unit == 35 || (unit == 45 && index + 1 < units.count && units[index + 1] == 45) {
                while index < units.count, units[index] != 10 { index += 1 }
            } else if unit == 47, index + 1 < units.count, units[index + 1] == 42 {
                index += 2
                while index + 1 < units.count, !(units[index] == 42 && units[index + 1] == 47) { index += 1 }
                index = min(index + 2, units.count)
            } else if isWordUnit(unit) {
                var end = index
                while end < units.count, isWordUnit(units[end]) { end += 1 }
                tokens.append(String(utf16CodeUnits: Array(units[index..<end]), count: end - index))
                index = end
            } else {
                if unit > 32 { tokens.append(String(utf16CodeUnits: [unit], count: 1)) }
                index += 1
            }
        }
        return tokens
    }

    /// A token as a name: a plain word, or a backtick-quoted name without its backticks.
    static func identifier(_ token: String) -> String? {
        if token.hasPrefix("`") {
            let inner = token.dropFirst().dropLast(token.hasSuffix("`") && token.count > 1 ? 1 : 0)
            return inner.isEmpty ? nil : String(inner)
        }
        guard let first = token.utf16.first, isWordUnit(first) else { return nil }
        return token
    }

    static func isReserved(_ word: String) -> Bool {
        let upper = word.uppercased()
        return SQLHighlighter.keywords.contains(upper) || ["NATURAL", "STRAIGHT_JOIN", "FORCE", "PARTITION"].contains(upper)
    }

    /// A name as it goes into SQL: backticks when it is not a plain word or is a keyword.
    public static func quoted(_ name: String) -> String {
        let plain = !name.isEmpty && name.utf16.allSatisfy(isWordUnit) && !(name.first?.isNumber ?? false)
        return plain && !isReserved(name) ? name : SQLQuote.identifier(name)
    }

    private static func tableItem(_ table: CompletionCatalog.Table) -> Completion {
        Completion(kind: table.isView ? .view : .table, name: table.name, detail: table.isView ? "view" : "table",
                   insertText: quoted(table.name))
    }

    private static func databaseItem(_ name: String) -> Completion {
        Completion(kind: .database, name: name, detail: "database", insertText: quoted(name))
    }

    private static func columnItem(_ column: CompletionCatalog.Column, table: String) -> Completion {
        Completion(kind: .column, name: column.name, detail: "\(column.type) · \(table)", insertText: quoted(column.name))
    }
}
