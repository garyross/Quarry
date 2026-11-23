import Foundation

/// The text Show Create Statement and Copy Create Statement give (S-028):
/// one object's statement as the server printed it, or several, each with a
/// comment line, so the whole runs as a script.
public enum CreateScript {
    public struct Item: Sendable, Hashable {
        public var object: DBObject
        public var statement: String

        public init(object: DBObject, statement: String) {
            self.object = object
            self.statement = statement
        }
    }

    /// "table", "view", "procedure", "function".
    public static func noun(_ kind: ObjectKind) -> String {
        switch kind {
        case .table: "table"
        case .view: "view"
        case .procedure: "procedure"
        case .function: "function"
        }
    }

    /// Each statement ends with ";". A routine's body holds semicolons, so it
    /// sits between DELIMITER ;; lines, as Sequel Pro wrote procedures.
    /// Several objects get a "-- Create statement for table `orders`" line each.
    public static func text(_ items: [Item]) -> String {
        items.map { item in
            let statement = trimmed(item.statement)
            let body = switch item.object.kind {
            case .procedure, .function: "DELIMITER ;;\n\(statement);;\nDELIMITER ;"
            case .table, .view: statement + ";"
            }
            guard items.count > 1 else { return body }
            return "-- Create statement for \(noun(item.object.kind)) \(SQLQuote.identifier(item.object.name))\n" + body
        }
        .joined(separator: "\n\n")
    }

    /// The Save As… name: "orders.sql" for one object, "quarry_demo.sql" for several.
    public static func fileName(_ items: [Item], database: String) -> String {
        let base = items.count == 1 ? items[0].object.name : database
        let safe = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return (safe.isEmpty ? "create" : safe) + ".sql"
    }

    /// No trailing whitespace or semicolon, so exactly one ";" is added.
    private static func trimmed(_ statement: String) -> String {
        var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") { text.removeLast(); text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return text
    }
}
