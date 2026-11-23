import Foundation

/// Who a view or routine runs as (SQL SECURITY), S-030.
public enum SQLSecurity: String, Sendable, CaseIterable {
    case definer = "DEFINER", invoker = "INVOKER"

    public var title: String { rawValue.capitalized }
}

/// How the server runs a view (ALGORITHM), S-030.
public enum ViewAlgorithm: String, Sendable, CaseIterable {
    case undefined = "UNDEFINED", merge = "MERGE", temptable = "TEMPTABLE"

    public var title: String {
        switch self {
        case .undefined: "Undefined"
        case .merge: "Merge"
        case .temptable: "Temporary Table"
        }
    }
}

/// WITH CHECK OPTION on an updatable view, S-030.
public enum ViewCheckOption: String, Sendable, CaseIterable {
    case none = "NONE", cascaded = "CASCADED", local = "LOCAL"

    public var title: String { rawValue.capitalized }
}

/// What a routine's body does with data (its SQL data access characteristic), S-030.
public enum RoutineDataAccess: String, Sendable, CaseIterable {
    case containsSQL = "CONTAINS SQL", noSQL = "NO SQL", readsSQLData = "READS SQL DATA", modifiesSQLData = "MODIFIES SQL DATA"

    public var title: String {
        switch self {
        case .containsSQL: "Contains SQL"
        case .noSQL: "No SQL"
        case .readsSQLData: "Reads SQL Data"
        case .modifiesSQLData: "Modifies SQL Data"
        }
    }
}

/// A view: its name, options and SELECT statement (S-030).
public struct ViewDefinition: Sendable, Hashable {
    public var name: String
    public var algorithm: ViewAlgorithm
    public var security: SQLSecurity
    public var checkOption: ViewCheckOption
    public var select: String

    public init(name: String, algorithm: ViewAlgorithm = .undefined, security: SQLSecurity = .definer,
                checkOption: ViewCheckOption = .none, select: String) {
        self.name = name
        self.algorithm = algorithm
        self.security = security
        self.checkOption = checkOption
        self.select = select
    }
}

/// A stored procedure or function: its name, parameters, return type (functions),
/// characteristics and body (S-030).
public struct RoutineDefinition: Sendable, Hashable {
    public var kind: ObjectKind
    public var name: String
    /// The text between the parentheses: "IN customer INT, OUT total DECIMAL(10,2)".
    public var parameters: String
    /// A function's return type ("INT"); ignored for procedures.
    public var returns: String
    public var deterministic: Bool
    public var dataAccess: RoutineDataAccess
    public var security: SQLSecurity
    public var comment: String
    public var body: String

    public init(kind: ObjectKind, name: String, parameters: String = "", returns: String = "", deterministic: Bool = false,
                dataAccess: RoutineDataAccess = .containsSQL, security: SQLSecurity = .definer, comment: String = "",
                body: String) {
        self.kind = kind
        self.name = name
        self.parameters = parameters
        self.returns = returns
        self.deterministic = deterministic
        self.dataAccess = dataAccess
        self.security = security
        self.comment = comment
        self.body = body
    }

    public var isFunction: Bool { kind == .function }
}

/// The statements that create, change and drop views and routines (S-030).
public enum DefinitionChange {
    /// The steps that make an object match a definition. `drop` runs first;
    /// a failed `create` runs `restore` (the first that works) and reports the
    /// error; `cleanup` runs after a create that worked (a renamed view's old name).
    public struct Plan: Sendable, Equatable {
        public var drop: String?
        public var create: String
        public var restore: [String]
        public var cleanup: String?
    }

    // MARK: Views

    /// "CREATE [OR REPLACE] [ALGORITHM=…] [SQL SECURITY …] VIEW `db`.`name` AS select [WITH … CHECK OPTION]".
    /// Options on their defaults are left out.
    public static func createSQL(_ view: ViewDefinition, in database: String, orReplace: Bool = false) -> String {
        var sql = orReplace ? "CREATE OR REPLACE" : "CREATE"
        if view.algorithm != .undefined { sql += " ALGORITHM=" + view.algorithm.rawValue }
        if view.security != .definer { sql += " SQL SECURITY " + view.security.rawValue }
        sql += " VIEW " + SQLQuote.qualified(database, view.name) + " AS\n" + trimmed(view.select)
        if view.checkOption != .none { sql += "\nWITH " + view.checkOption.rawValue + " CHECK OPTION" }
        return sql
    }

    /// A new view: one CREATE. The same name: CREATE OR REPLACE, which keeps the
    /// old view when it fails. A new name: CREATE the new one, then drop the old.
    public static func plan(_ view: ViewDefinition, replacing original: ViewDefinition?, in database: String) -> Plan {
        guard let original else { return Plan(drop: nil, create: createSQL(view, in: database), restore: [], cleanup: nil) }
        if original.name == view.name {
            return Plan(drop: nil, create: createSQL(view, in: database, orReplace: true), restore: [], cleanup: nil)
        }
        return Plan(drop: nil, create: createSQL(view, in: database), restore: [],
                    cleanup: dropSQL(.view, original.name, in: database))
    }

    /// SQLite's views (S-070): CREATE VIEW "name" AS select, with none of MySQL's options.
    public static func sqliteCreateSQL(_ view: ViewDefinition) -> String {
        "CREATE VIEW " + SQLiteTable.quote(view.name) + " AS\n" + trimmed(view.select)
    }

    /// SQLite has no CREATE OR REPLACE VIEW: the same name drops and creates, putting the original back on an error.
    public static func plan(_ view: ViewDefinition, replacing original: ViewDefinition?, in database: String,
                            engine: Engine) -> Plan {
        guard engine == .sqlite else { return plan(view, replacing: original, in: database) }
        guard let original else { return Plan(drop: nil, create: sqliteCreateSQL(view), restore: [], cleanup: nil) }
        if original.name == view.name {
            return Plan(drop: "DROP VIEW " + SQLiteTable.quote(original.name), create: sqliteCreateSQL(view),
                        restore: [sqliteCreateSQL(original)], cleanup: nil)
        }
        return Plan(drop: nil, create: sqliteCreateSQL(view), restore: [], cleanup: "DROP VIEW " + SQLiteTable.quote(original.name))
    }

    /// The SELECT after AS in a CREATE VIEW; nil when it has none.
    public static func viewSelect(inCreate sql: String) -> String? {
        let tokens = SQLiteTokens(sql).tokens
        var depth = 0
        for (index, token) in tokens.enumerated() {
            if token.kind == .open { depth += 1 }
            if token.kind == .close { depth -= 1 }
            if depth == 0, token.upper == "AS", index + 1 < tokens.count {
                return String(sql[tokens[index + 1].range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    // MARK: Routines

    /// "CREATE PROCEDURE `db`.`name`(params)" or "CREATE FUNCTION `db`.`name`(params) RETURNS type",
    /// then the characteristics that differ from the defaults, then the body.
    public static func createSQL(_ routine: RoutineDefinition, in database: String) -> String {
        var sql = "CREATE " + keyword(routine.kind) + " " + SQLQuote.qualified(database, routine.name)
            + "(" + routine.parameters.trimmingCharacters(in: .whitespacesAndNewlines) + ")"
        if routine.isFunction { sql += " RETURNS " + routine.returns.trimmingCharacters(in: .whitespacesAndNewlines) }
        var characteristics: [String] = []
        if routine.deterministic { characteristics.append("DETERMINISTIC") }
        if routine.dataAccess != .containsSQL { characteristics.append(routine.dataAccess.rawValue) }
        if routine.security != .definer { characteristics.append("SQL SECURITY " + routine.security.rawValue) }
        let comment = routine.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty { characteristics.append("COMMENT " + SQLQuote.mysqlLiteral(comment)) }
        if !characteristics.isEmpty { sql += "\n" + characteristics.joined(separator: " ") }
        return sql + "\n" + trimmed(routine.body)
    }

    /// The server has no way to change a routine's body in place, so an edit
    /// drops it and creates it again. When the create fails, the original comes
    /// back: first its own statement (`originalStatement`, from SHOW CREATE),
    /// then one built from its parts.
    public static func plan(_ routine: RoutineDefinition, replacing original: RoutineDefinition?,
                            originalStatement: String? = nil, in database: String) -> Plan {
        guard let original else { return Plan(drop: nil, create: createSQL(routine, in: database), restore: [], cleanup: nil) }
        var restore: [String] = []
        if let statement = originalStatement?.trimmingCharacters(in: .whitespacesAndNewlines), !statement.isEmpty {
            restore.append(statement)
        }
        restore.append(createSQL(original, in: database))
        return Plan(drop: dropSQL(original.kind, original.name, in: database), create: createSQL(routine, in: database),
                    restore: restore, cleanup: nil)
    }

    // MARK: Shared

    public static func dropSQL(_ kind: ObjectKind, _ name: String, in database: String) -> String {
        "DROP " + keyword(kind) + " " + SQLQuote.qualified(database, name)
    }

    public static func keyword(_ kind: ObjectKind) -> String {
        switch kind {
        case .table: "TABLE"
        case .view: "VIEW"
        case .procedure: "PROCEDURE"
        case .function: "FUNCTION"
        }
    }

    /// Why a name can't be used, or nil (also for an empty name). Views share
    /// their names with tables; procedures and functions each have their own.
    public static func nameProblem(_ name: String, kind: ObjectKind, existing: [DBObject], original: String?) -> String? {
        let noun = CreateScript.noun(kind)
        let others = existing.filter { object in
            let sameSpace = kind.hasRows ? object.kind.hasRows : object.kind == kind
            return sameSpace && object.name.caseInsensitiveCompare(original ?? "") != .orderedSame
        }
        let taken = kind.hasRows ? "A table or view" : (kind == .procedure ? "A procedure" : "A function")
        return SchemaName.problem(with: name, noun: noun, existing: others.map(\.name), taken: taken)
    }

    /// The parameter list in a SHOW CREATE PROCEDURE or FUNCTION statement:
    /// the text inside the first parentheses after the keyword, quotes and
    /// nested parentheses (DECIMAL(10,2)) included.
    public static func parameters(inCreate statement: String, kind: ObjectKind) -> String? {
        let scalars = Array(statement.unicodeScalars)
        let word = Array(keyword(kind).unicodeScalars)
        var index = 0
        var quote: Unicode.Scalar?
        var start: Int?
        // Find the keyword outside quotes (a DEFINER can hold any text).
        while index < scalars.count, start == nil {
            let character = scalars[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "`" || character == "'" || character == "\"" {
                quote = character
            } else if index + word.count <= scalars.count,
                      String(String.UnicodeScalarView(scalars[index ..< index + word.count])).uppercased() == keyword(kind),
                      index == 0 || scalars[index - 1].properties.isWhitespace {
                start = index + word.count
            }
            index += 1
        }
        guard var index = start else { return nil }
        quote = nil
        var depth = 0
        var open: Int?
        while index < scalars.count {
            let character = scalars[index]
            if let current = quote {
                if character == current { quote = nil }
            } else if character == "`" || character == "'" || character == "\"" {
                quote = character
            } else if character == "(" {
                if depth == 0 { open = index + 1 }
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0, let open {
                    return String(String.UnicodeScalarView(scalars[open ..< index])).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            index += 1
        }
        return nil
    }

    /// "ALGORITHM=MERGE" in a SHOW CREATE VIEW statement.
    public static func algorithm(inCreate statement: String) -> ViewAlgorithm {
        guard let range = statement.range(of: "ALGORITHM=", options: .caseInsensitive) else { return .undefined }
        let word = statement[range.upperBound...].prefix { $0.isLetter }
        return ViewAlgorithm(rawValue: word.uppercased()) ?? .undefined
    }

    /// No surrounding blank lines and no final semicolon.
    static func trimmed(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
