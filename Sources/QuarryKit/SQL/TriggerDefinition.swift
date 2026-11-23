import Foundation

/// When a trigger runs: before or after the row changes (S-026).
public enum TriggerTiming: String, Sendable, CaseIterable {
    case before = "BEFORE", after = "AFTER"

    public var title: String { rawValue.capitalized }
}

/// Which change runs a trigger (S-026).
public enum TriggerEvent: String, Sendable, CaseIterable {
    case insert = "INSERT", update = "UPDATE", delete = "DELETE"

    public var title: String { rawValue.capitalized }
}

/// A trigger on one table: its name, when it runs, and its statement (the
/// part after FOR EACH ROW, often a BEGIN … END block).
public struct TriggerDefinition: Sendable, Hashable {
    public var name: String
    public var timing: TriggerTiming
    public var event: TriggerEvent
    public var statement: String
    /// SQLite's UPDATE OF fields ("stock, price"), kept as they were; empty for any field (S-070).
    public var columns: String

    public init(name: String, timing: TriggerTiming = .before, event: TriggerEvent = .insert, statement: String,
                columns: String = "") {
        self.name = name
        self.timing = timing
        self.event = event
        self.statement = statement
        self.columns = columns
    }

    /// Reads SHOW TRIGGERS' rows (Trigger, Timing, Event, Statement). Rows it can't read are left out.
    public static func list(from result: StatementResult) -> [TriggerDefinition] {
        result.rows.indices.compactMap { row in
            guard let name = result.string(row, "Trigger"),
                  let timing = result.string(row, "Timing").flatMap({ TriggerTiming(rawValue: $0.uppercased()) }),
                  let event = result.string(row, "Event").flatMap({ TriggerEvent(rawValue: $0.uppercased()) })
            else { return nil }
            // Some servers pad the statement with NUL bytes (Sequel Pro trimmed them too).
            let statement = (result.string(row, "Statement") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            return TriggerDefinition(name: name, timing: timing, event: event, statement: statement,
                                     columns: result.string(row, "Columns") ?? "")
        }
    }

    /// The statement as it is sent: no surrounding blank lines and no final semicolon.
    public var trimmedStatement: String {
        var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

public enum TriggerChange {
    /// "CREATE TRIGGER `db`.`name` BEFORE UPDATE ON `db`.`table` FOR EACH ROW", without the statement.
    public static func header(_ trigger: TriggerDefinition, on table: String, in database: String) -> String {
        "CREATE TRIGGER " + SQLQuote.qualified(database, trigger.name) + " " + trigger.timing.rawValue + " "
            + trigger.event.rawValue + " ON " + SQLQuote.qualified(database, table) + " FOR EACH ROW"
    }

    public static func createSQL(_ trigger: TriggerDefinition, on table: String, in database: String,
                                 engine: Engine) -> String {
        guard engine == .sqlite else { return header(trigger, on: table, in: database) + "\n" + trigger.trimmedStatement }
        // SQLite: the table can't be qualified, and the body is a BEGIN … END block, after an optional WHEN.
        let columns = trigger.event == .update && !trigger.columns.isEmpty ? " OF " + trigger.columns : ""
        var body = trigger.trimmedStatement
        let upper = body.uppercased()
        if !upper.hasPrefix("WHEN"), !upper.hasPrefix("BEGIN") { body = "BEGIN\n  " + body + ";\nEND" }
        return "CREATE TRIGGER " + SQLiteTable.quote(trigger.name) + " " + trigger.timing.rawValue + " " + trigger.event.rawValue
            + columns + " ON " + SQLiteTable.quote(table) + "\n" + body
    }

    public static func dropSQL(_ name: String, in database: String) -> String {
        "DROP TRIGGER " + SQLQuote.qualified(database, name)
    }

    /// The steps that replace `original` with `trigger`. The server has no ALTER
    /// TRIGGER, so it is a drop and a create; `restore` puts the original back
    /// when the create fails. A new trigger has one step and nothing to restore.
    public struct Plan: Sendable, Equatable {
        public var drop: String?
        public var create: String
        public var restore: String?
    }

    public static func plan(_ trigger: TriggerDefinition, replacing original: TriggerDefinition?,
                            on table: String, in database: String, engine: Engine) -> Plan {
        Plan(drop: original.map { dropSQL($0.name, in: database) },
             create: createSQL(trigger, on: table, in: database, engine: engine),
             restore: original.map { createSQL($0, on: table, in: database, engine: engine) })
    }

    /// Why a name can't be used, or nil. Trigger names are unique in a database, ignoring case.
    public static func nameProblem(_ name: String, taken: [String], original: String?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.count > 64 { return "A trigger name can have up to 64 characters." }
        let others = taken.filter { $0.caseInsensitiveCompare(original ?? "") != .orderedSame }
        if others.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "A trigger named \u{201C}\(trimmed)\u{201D} already exists in this database."
        }
        return nil
    }

    /// A starting name, like Sequel Pro's: "orders_before_insert", then "_2", "_3" when taken.
    public static func suggestedName(table: String, timing: TriggerTiming, event: TriggerEvent, taken: [String]) -> String {
        let base = "\(table)_\(timing.rawValue.lowercased())_\(event.rawValue.lowercased())"
        let lower = Set(taken.map { $0.lowercased() })
        if !lower.contains(base.lowercased()) { return base }
        var number = 2
        while lower.contains("\(base)_\(number)".lowercased()) { number += 1 }
        return "\(base)_\(number)"
    }
}
