/// Quoting for identifiers and string literals. Every name or value Quarry puts
/// into SQL goes through here.
public enum SQLQuote {
    /// `name` with backticks doubled: `my``table`.
    public static func identifier(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// `db`.`table`
    public static func qualified(_ database: String, _ name: String) -> String {
        identifier(database) + "." + identifier(name)
    }

    /// 'text' with MySQL's escapes, safe in the default sql_mode and with
    /// NO_BACKSLASH_ESCAPES off. Only for SQL that runs on MySQL alone
    /// (information_schema, GRANT, COMMENT clauses); a value for a connection
    /// that may be a SQLite file goes through `literal(_:engine:)`.
    public static func mysqlLiteral(_ value: String) -> String {
        var out = "'"
        for character in value.unicodeScalars {
            switch character {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\0": out += "\\0"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{1A}": out += "\\Z"
            default: out.unicodeScalars.append(character)
            }
        }
        return out + "'"
    }

    /// 'text' as `engine` reads it. SQLite has no backslash escapes: a quote is
    /// doubled and every other character, backslash and line break too, stays as is.
    public static func literal(_ value: String, engine: Engine) -> String {
        switch engine {
        case .mysql: mysqlLiteral(value)
        case .sqlite: "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
    }
}
