import Foundation

/// A CREATE TABLE statement as SQLite keeps it in sqlite_schema, split into
/// its columns, table constraints and options (S-070), so a table rebuild can
/// change one column and write every other part back as it was.
public struct SQLiteTable: Sendable, Equatable {
    public var columns: [SQLiteColumn]
    /// PRIMARY KEY (…), UNIQUE (…), CHECK (…) and FOREIGN KEY (…) clauses, as written.
    public var constraints: [SQLiteConstraint]
    /// What follows the closing parenthesis: "STRICT", "WITHOUT ROWID", or both; empty for none.
    public var options: String

    public init(columns: [SQLiteColumn], constraints: [SQLiteConstraint] = [], options: String = "") {
        self.columns = columns
        self.constraints = constraints
        self.options = options
    }

    /// Reads `CREATE TABLE name (…) options`; nil for CREATE TABLE … AS SELECT or text it can't read.
    public init?(sql: String) {
        let tokens = SQLiteTokens(sql).tokens
        guard let open = tokens.firstIndex(where: { $0.kind == .open }),
              let close = SQLiteTokens.matching(open, in: tokens) else { return nil }
        var columns: [SQLiteColumn] = []
        var constraints: [SQLiteConstraint] = []
        for segment in SQLiteTokens.split(tokens, from: open + 1, to: close) {
            guard let first = segment.first else { continue }
            if ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"].contains(first.upper) {
                constraints.append(SQLiteConstraint(text: SQLiteTokens.text(sql, segment)))
            } else if let column = SQLiteColumn(tokens: segment, in: sql) {
                columns.append(column)
            } else {
                return nil
            }
        }
        guard !columns.isEmpty else { return nil }
        self.columns = columns
        self.constraints = constraints
        options = close + 1 < tokens.count ? SQLiteTokens.text(sql, Array(tokens[(close + 1)...]))
            .trimmingCharacters(in: CharacterSet(charactersIn: "; \n\t")) : ""
    }

    private var optionWords: String { options.uppercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
    public var isStrict: Bool { optionWords.contains("STRICT") }
    public var isWithoutRowID: Bool { optionWords.contains("WITHOUT ROWID") }

    /// The options Info shows: "STRICT", "WITHOUT ROWID".
    public var optionNames: [String] { (isStrict ? ["STRICT"] : []) + (isWithoutRowID ? ["WITHOUT ROWID"] : []) }

    public func column(named name: String) -> Int? {
        columns.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The statement that makes this table under `name`, one part per line.
    public func createSQL(named name: String) -> String {
        let parts = columns.map(\.sql) + constraints.map(\.text)
        return "CREATE TABLE " + SQLiteTable.quote(name) + " (\n  " + parts.joined(separator: ",\n  ") + "\n)"
            + (options.isEmpty ? "" : " " + options)
    }

    /// "name", with quotes doubled: the quoting SQLite itself writes into its schema.
    public static func quote(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    // MARK: Foreign keys

    /// Each foreign key's place: a column's REFERENCES, or a FOREIGN KEY clause, in the order
    /// SQLite read them. PRAGMA foreign_key_list numbers them from the last one (id 0) up.
    public enum KeyPlace: Sendable, Equatable {
        case column(Int, constraint: Int)
        case table(Int)
    }

    public var foreignKeyPlaces: [KeyPlace] {
        var places: [KeyPlace] = []
        for (index, column) in columns.enumerated() {
            for (number, constraint) in column.constraints.enumerated() where constraint.kind == "REFERENCES" {
                places.append(.column(index, constraint: number))
            }
        }
        for (index, constraint) in constraints.enumerated() where constraint.kind == "FOREIGN" {
            places.append(.table(index))
        }
        return places
    }

    /// The table without the foreign keys PRAGMA foreign_key_list calls `ids`.
    public func removingForeignKeys(ids: [Int]) throws -> SQLiteTable {
        let places = foreignKeyPlaces
        let doomed = try ids.map { id -> KeyPlace in
            guard id >= 0, id < places.count else { throw DatabaseError(message: "The foreign key is no longer in the table.") }
            return places[places.count - 1 - id]
        }
        var table = self
        var columnDrops: [Int: Set<Int>] = [:]
        var tableDrops = Set<Int>()
        for place in doomed {
            switch place {
            case .column(let column, let constraint): columnDrops[column, default: []].insert(constraint)
            case .table(let index): tableDrops.insert(index)
            }
        }
        for (column, numbers) in columnDrops {
            table.columns[column].constraints = table.columns[column].constraints.enumerated()
                .filter { !numbers.contains($0.offset) }.map(\.element)
        }
        table.constraints = table.constraints.enumerated().filter { !tableDrops.contains($0.offset) }.map(\.element)
        return table
    }
}

/// One column of a CREATE TABLE: its name, declared type and constraints, each kept as written.
public struct SQLiteColumn: Sendable, Equatable {
    public var name: String
    /// The type as declared, "VARCHAR(255)"; empty for none.
    public var type: String
    public var constraints: [SQLiteConstraint]

    public init(name: String, type: String, constraints: [SQLiteConstraint] = []) {
        self.name = name
        self.type = type
        self.constraints = constraints
    }

    init?(tokens: [SQLiteToken], in sql: String) {
        guard let first = tokens.first, first.kind == .word || first.kind == .quoted || first.kind == .string else { return nil }
        name = first.name
        var index = 1
        var typeTokens: [SQLiteToken] = []
        while index < tokens.count, !SQLiteColumn.startsConstraint(tokens, index) {
            if tokens[index].kind == .open, let end = SQLiteTokens.matching(index, in: tokens) {
                typeTokens += tokens[index...end]
                index = end + 1
            } else {
                typeTokens.append(tokens[index])
                index += 1
            }
        }
        type = typeTokens.isEmpty ? "" : SQLiteTokens.text(sql, typeTokens)
        constraints = []
        while index < tokens.count {
            let start = index
            var kindIndex = index
            if tokens[index].upper == "CONSTRAINT" { kindIndex = min(index + 2, tokens.count - 1) }
            let kind = tokens[kindIndex].upper
            index = kindIndex + 1
            func takeOne() {
                guard index < tokens.count else { return }
                if tokens[index].kind == .open, let end = SQLiteTokens.matching(index, in: tokens) { index = end + 1 } else { index += 1 }
            }
            switch kind {
            case "DEFAULT":
                if index < tokens.count, ["-", "+"].contains(tokens[index].text) { index += 1 }
                takeOne()
            case "COLLATE":
                takeOne()
            default:
                if kind == "NOT", index < tokens.count, tokens[index].upper == "NULL" { index += 1 }
                while index < tokens.count, !SQLiteColumn.startsConstraint(tokens, index, within: kind) { takeOne() }
            }
            constraints.append(SQLiteConstraint(text: SQLiteTokens.text(sql, Array(tokens[start..<min(index, tokens.count)]))))
        }
    }

    static let constraintWords: Set<String> = ["CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT",
                                                "COLLATE", "REFERENCES", "GENERATED", "AS"]

    /// Whether a new constraint starts at `index`: SET NULL, NOT DEFERRABLE and GENERATED ALWAYS AS stay in theirs.
    static func startsConstraint(_ tokens: [SQLiteToken], _ index: Int, within kind: String = "") -> Bool {
        let token = tokens[index]
        guard token.kind == .word, constraintWords.contains(token.upper) else { return false }
        let previous = index > 0 ? tokens[index - 1].upper : ""
        if token.upper == "NULL", previous == "SET" { return false }
        if token.upper == "NOT", index + 1 < tokens.count, tokens[index + 1].upper == "DEFERRABLE" { return false }
        if token.upper == "AS", kind == "GENERATED" { return false }
        return true
    }

    /// The column as CREATE TABLE writes it.
    public var sql: String {
        ([SQLiteTable.quote(name)] + (type.isEmpty ? [] : [type]) + constraints.map(\.text)).joined(separator: " ")
    }

    private func first(_ kind: String) -> SQLiteConstraint? { constraints.first { $0.kind == kind } }

    public var isNotNull: Bool { first("NOT") != nil }
    public var isPrimaryKey: Bool { first("PRIMARY") != nil }
    public var isAutoIncrement: Bool { first("PRIMARY")?.words.contains("AUTOINCREMENT") == true }
    public var isGenerated: Bool { first("GENERATED") != nil || first("AS") != nil }
    public var hasReferences: Bool { first("REFERENCES") != nil }
    public var isUnique: Bool { first("UNIQUE") != nil }

    /// The default as written after DEFAULT: 'US', 0, CURRENT_TIMESTAMP, (datetime('now')).
    public var defaultSQL: String? { first("DEFAULT")?.argument }
    /// The collation after COLLATE: NOCASE.
    public var collation: String? { first("COLLATE")?.argument.map(SQLiteToken.unquote) }

    /// Puts `text` (the whole constraint) in place of the first of `kind`, or at the end; nil removes every one.
    mutating func replace(_ kind: String, with text: String?) {
        let at = constraints.firstIndex { $0.kind == kind }
        constraints.removeAll { $0.kind == kind }
        guard let text else { return }
        constraints.insert(SQLiteConstraint(text: text), at: min(at ?? constraints.count, constraints.count))
    }

    public mutating func setNotNull(_ on: Bool) {
        if on, isNotNull { return }
        constraints.removeAll { $0.kind == "NULL" }
        replace("NOT", with: on ? "NOT NULL" : nil)
    }

    public mutating func setDefault(_ sql: String?) { replace("DEFAULT", with: sql.map { "DEFAULT " + $0 }) }

    public mutating func setCollation(_ name: String?) {
        replace("COLLATE", with: name.flatMap { $0.isEmpty ? nil : "COLLATE " + $0 })
    }

    /// AUTOINCREMENT on or off in the column's PRIMARY KEY.
    public mutating func setAutoIncrement(_ on: Bool) {
        guard let index = constraints.firstIndex(where: { $0.kind == "PRIMARY" }), on != isAutoIncrement else {
            if on, !isPrimaryKey { constraints.insert(SQLiteConstraint(text: "PRIMARY KEY AUTOINCREMENT"), at: 0) }
            return
        }
        var text = constraints[index].text
        if on {
            text += " AUTOINCREMENT"
        } else {
            text = text.replacingOccurrences(of: #"\s+AUTOINCREMENT\b"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        constraints[index] = SQLiteConstraint(text: text)
    }
}

/// One constraint, as written: `NOT NULL`, `DEFAULT 'US'`, `REFERENCES customers(id) ON DELETE CASCADE`.
public struct SQLiteConstraint: Sendable, Equatable {
    public var text: String

    public init(text: String) { self.text = text }

    var words: [String] { SQLiteTokens(text).tokens.map(\.upper) }

    /// The keyword that names it, after any CONSTRAINT name: PRIMARY, NOT, DEFAULT, REFERENCES, FOREIGN, …
    public var kind: String {
        let tokens = SQLiteTokens(text).tokens
        guard let first = tokens.first else { return "" }
        return first.upper == "CONSTRAINT" ? (tokens.count > 2 ? tokens[2].upper : "") : first.upper
    }

    /// What follows the keyword (DEFAULT's value, COLLATE's name).
    var argument: String? {
        let tokens = SQLiteTokens(text).tokens
        guard let at = tokens.firstIndex(where: { $0.upper == kind }), at + 1 < tokens.count else { return nil }
        return SQLiteTokens.text(text, Array(tokens[(at + 1)...]))
    }

    /// The columns of a table-level PRIMARY KEY (…), lowercased.
    public var keyColumns: [String] {
        let tokens = SQLiteTokens(text).tokens
        guard let open = tokens.firstIndex(where: { $0.kind == .open }),
              let close = SQLiteTokens.matching(open, in: tokens) else { return [] }
        return SQLiteTokens.split(tokens, from: open + 1, to: close).compactMap { $0.first?.name.lowercased() }
    }
}

// MARK: Tokens

struct SQLiteToken: Sendable {
    enum Kind { case word, quoted, string, number, open, close, comma, symbol }
    let kind: Kind
    let text: String
    let range: Range<String.Index>

    var upper: String { kind == .word ? text.uppercased() : "" }

    /// A name with its quotes taken off: "a""b", `a`, [a] and 'a' all name a.
    var name: String { SQLiteToken.unquote(text) }

    static func unquote(_ text: String) -> String {
        guard let first = text.first, text.count >= 2 else { return text }
        switch first {
        case "\"": return String(text.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        case "`": return String(text.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`")
        case "'": return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        case "[": return String(text.dropFirst().dropLast())
        default: return text
        }
    }
}

/// SQLite's tokens, enough to find parentheses, commas and keywords; comments are skipped.
struct SQLiteTokens {
    let tokens: [SQLiteToken]

    init(_ sql: String) {
        var tokens: [SQLiteToken] = []
        var index = sql.startIndex
        func add(_ kind: SQLiteToken.Kind, _ start: String.Index) {
            tokens.append(SQLiteToken(kind: kind, text: String(sql[start..<index]), range: start..<index))
        }
        func skip(past end: Character) {
            while index < sql.endIndex {
                let character = sql[index]
                index = sql.index(after: index)
                if character == end {
                    // A doubled quote is one quote inside the name or string.
                    if end != "]", index < sql.endIndex, sql[index] == end { index = sql.index(after: index); continue }
                    return
                }
            }
        }
        while index < sql.endIndex {
            let start = index
            let character = sql[index]
            let next = sql.index(after: index) < sql.endIndex ? sql[sql.index(after: index)] : nil
            if character.isWhitespace {
                index = sql.index(after: index)
            } else if character == "-", next == "-" {
                while index < sql.endIndex, sql[index] != "\n" { index = sql.index(after: index) }
            } else if character == "/", next == "*" {
                index = sql.index(index, offsetBy: 2)
                while index < sql.endIndex, !(sql[index] == "*" && sql.index(after: index) < sql.endIndex
                                               && sql[sql.index(after: index)] == "/") {
                    index = sql.index(after: index)
                }
                index = index < sql.endIndex ? sql.index(index, offsetBy: 2) : index
            } else if character == "'" {
                index = sql.index(after: index); skip(past: "'"); add(.string, start)
            } else if character == "\"" || character == "`" {
                index = sql.index(after: index); skip(past: character); add(.quoted, start)
            } else if character == "[" {
                index = sql.index(after: index); skip(past: "]"); add(.quoted, start)
            } else if (character == "x" || character == "X"), next == "'" {
                index = sql.index(index, offsetBy: 2); skip(past: "'"); add(.string, start)
            } else if character.isNumber || (character == "." && next?.isNumber == true) {
                while index < sql.endIndex, sql[index].isNumber || sql[index].isLetter || sql[index] == "." {
                    index = sql.index(after: index)
                }
                add(.number, start)
            } else if character.isLetter || character == "_" || character == "$" || !character.isASCII {
                while index < sql.endIndex, sql[index].isLetter || sql[index].isNumber || sql[index] == "_"
                        || sql[index] == "$" || !sql[index].isASCII {
                    index = sql.index(after: index)
                }
                add(.word, start)
            } else {
                index = sql.index(after: index)
                add(character == "(" ? .open : character == ")" ? .close : character == "," ? .comma : .symbol, start)
            }
        }
        self.tokens = tokens
    }

    static func matching(_ open: Int, in tokens: [SQLiteToken]) -> Int? {
        var depth = 0
        for index in open..<tokens.count {
            if tokens[index].kind == .open { depth += 1 }
            if tokens[index].kind == .close {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    /// The tokens between `start` and `end`, split at commas outside parentheses.
    static func split(_ tokens: [SQLiteToken], from start: Int, to end: Int) -> [[SQLiteToken]] {
        var segments: [[SQLiteToken]] = [[]]
        var depth = 0
        for index in start..<end {
            let token = tokens[index]
            if token.kind == .open { depth += 1 }
            if token.kind == .close { depth -= 1 }
            if token.kind == .comma, depth == 0 { segments.append([]) } else { segments[segments.count - 1].append(token) }
        }
        return segments.filter { !$0.isEmpty }
    }

    /// The text from the first token to the last, as written (comments and spacing kept).
    static func text(_ sql: String, _ tokens: [SQLiteToken]) -> String {
        guard let first = tokens.first, let last = tokens.last else { return "" }
        return String(sql[first.range.lowerBound..<last.range.upperBound])
    }
}
