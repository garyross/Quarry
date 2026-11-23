import Foundation
import QuarryKit

/// Schema tools, table schemas as resources, and name completion (S-063).
extension AgentTools {
    func listDatabases(_ args: ToolArgs, model: AppModel) async throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        let names = try await connections.run(target) { try await $0.databases() }
        var result: [String: JSONValue] = ["connection": .string(target.id), "databases": .array(names.map(JSONValue.string))]
        if let shown = target.session?.database { result["windowDatabase"] = .string(shown) }
        return .object(result)
    }

    func listTables(_ args: ToolArgs, model: AppModel) async throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        let database = try database(args, target)
        let result = try await connections.run(target) { try await $0.run($0.dialect.agentTablesSQL(in: database)) }
        let tables: [JSONValue] = result.rows.indices.map { row in
            var item: [String: JSONValue] = [
                "name": .optional(result.string(row, "name")),
                "kind": .string((result.string(row, "type") ?? "").uppercased().contains("VIEW") ? "view" : "table"),
            ]
            if let engine = result.string(row, "engine") { item["engine"] = .string(engine) }
            if let rows = result.string(row, "rows_estimate").flatMap(Int.init) { item["rowsEstimate"] = .int(rows) }
            if let comment = result.string(row, "comment"), !comment.isEmpty, comment != "VIEW" { item["comment"] = .string(comment) }
            return .object(item)
        }
        return ["database": .string(database), "tables": .array(tables)]
    }

    func listRoutines(_ args: ToolArgs, model: AppModel) async throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        let database = try database(args, target)
        let (routines, triggers, events) = try await connections.run(target) { client in
            let dialect = client.dialect
            var routines: StatementResult?
            if let sql = dialect.agentRoutinesSQL(in: database) { routines = try await client.run(sql) }
            let triggers = try await client.run(dialect.agentTriggersSQL(in: database))
            // Events need the EVENT privilege on some servers; a refusal leaves them out.
            var events: StatementResult?
            if let sql = dialect.agentEventsSQL(in: database) { events = try? await client.run(sql) }
            return (routines, triggers, events)
        }
        func kind(_ kind: String) -> [JSONValue] {
            guard let routines else { return [] }
            return routines.rows.indices.filter { routines.string($0, "kind") == kind }.map { row in
                var item: [String: JSONValue] = ["name": .optional(routines.string(row, "name"))]
                if kind == "FUNCTION" { item["returns"] = .optional(routines.string(row, "returns")) }
                if let comment = routines.string(row, "comment"), !comment.isEmpty { item["comment"] = .string(comment) }
                return .object(item)
            }
        }
        return ["database": .string(database),
                "procedures": .array(kind("PROCEDURE")),
                "functions": .array(kind("FUNCTION")),
                "triggers": .array(Self.triggers(triggers)),
                "events": .array(events.map { Self.records($0, ["name": "name", "status": "status", "type": "type",
                                                                "every": "every", "unit": "unit"]) } ?? [])]
    }

    /// Triggers as name, table, timing and event; SQLite's timing and event come from the CREATE TRIGGER (S-073).
    static func triggers(_ result: StatementResult) -> [JSONValue] {
        result.rows.indices.map { row in
            var timing = result.string(row, "timing") ?? ""
            var event = result.string(row, "event") ?? ""
            if timing.isEmpty, let statement = result.string(row, "statement") {
                let parsed = SQLiteTrigger(statement)
                (timing, event) = (parsed.timing, parsed.event)
            }
            return ["name": .optional(result.string(row, "name")), "table": .optional(result.string(row, "table")),
                    "timing": .string(timing), "event": .string(event)]
        }
    }

    func describeTable(_ args: ToolArgs, model: AppModel) async throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        let database = try database(args, target)
        return try await describe(try args.required("table"), in: database, target: target)
    }

    func describe(_ table: String, in database: String, target: AgentConnections.Target) async throws -> JSONValue {
        let (fields, indexes, keys, kind) = try await connections.run(target) { client in
            let kind = try await client.run(client.dialect.objectTypeSQL(of: table, in: database))
            guard let type = kind.rows.first?.first?.plainText else {
                throw MCPToolError("No table or view named \u{201C}\(table)\u{201D} in \(database). Run list_tables to see them.")
            }
            let isView = type.uppercased().contains("VIEW")
            return (try await client.fields(of: table, in: database),
                    isView ? nil : try await client.indexes(of: table, in: database),
                    isView ? [] : try await client.foreignKeys(of: table, in: database),
                    isView ? "view" : "table")
        }
        let columns: [JSONValue] = fields.map { field in
            var item: [String: JSONValue] = ["name": .string(field.name), "type": .string(field.fullType), "nullable": .bool(field.isNullable)]
            if !field.key.isEmpty { item["key"] = .string(field.key) }
            if let value = field.defaultValue { item["default"] = .string(value) }
            if !field.extra.isEmpty { item["extra"] = .string(field.extra) }
            if !field.comment.isEmpty { item["comment"] = .string(field.comment) }
            if let collation = field.collation { item["collation"] = .string(collation) }
            return .object(item)
        }
        var result: [String: JSONValue] = ["database": .string(database), "table": .string(table), "kind": .string(kind),
                                           "columns": .array(columns)]
        if let indexes {
            var order: [String] = []
            var grouped: [String: (unique: Bool, type: String, columns: [String])] = [:]
            for row in indexes.rows.indices {
                guard let name = indexes.string(row, "Key_name"), let column = indexes.string(row, "Column_name") else { continue }
                if grouped[name] == nil {
                    order.append(name)
                    grouped[name] = (indexes.string(row, "Non_unique") == "0", indexes.string(row, "Index_type") ?? "", [])
                }
                let part = indexes.string(row, "Sub_part").map { "\(column)(\($0))" } ?? column
                grouped[name]?.columns.append(part)
            }
            result["indexes"] = .array(order.compactMap { name in
                grouped[name].map { ["name": .string(name), "unique": .bool($0.unique), "type": .string($0.type),
                                     "columns": .array($0.columns.map(JSONValue.string))] }
            })
            result["foreignKeys"] = .array(keys.map { key in
                ["name": .string(key.name), "columns": .string(key.columns),
                 "references": .string((key.referencedDatabase == database ? "" : key.referencedDatabase + ".")
                                       + key.referencedTable + "(" + key.referencedColumns + ")"),
                 "onUpdate": .string(key.onUpdate), "onDelete": .string(key.onDelete)]
            })
        }
        return .object(result)
    }

    func createStatement(_ args: ToolArgs, model: AppModel) async throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        let database = try database(args, target)
        let name = try args.required("name")
        let asked = args.string("kind")?.lowercased()
        let kinds = ["table", "view", "procedure", "function", "trigger", "event"]
        if let asked, !kinds.contains(asked) { throw MCPToolError("kind is one of " + kinds.joined(separator: ", ") + ".") }
        let (kind, statement) = try await connections.run(target) { client -> (String, String) in
            let kind: String
            if let asked {
                kind = asked
            } else {
                let found = try await client.run(client.dialect.objectKindSQL(of: name, in: database))
                guard let first = found.rows.first?.first?.plainText else {
                    throw MCPToolError("Nothing named \u{201C}\(name)\u{201D} in \(database). Run list_tables or list_routines.")
                }
                kind = first
            }
            guard let text = try await client.createStatement(kind: kind, of: name, in: database) else {
                throw MCPToolError("The server didn’t give the create statement. The login may lack permission to see it.")
            }
            return (kind, text)
        }
        return ["database": .string(database), "name": .string(name), "kind": .string(kind), "statement": .string(statement)]
    }

    // MARK: Resources

    /// The tables of the frontmost window's database, from its sidebar (no query).
    func resources() async -> [MCPResource] {
        guard let model, let target = try? connections.target(nil, model: model), let session = target.session,
              let database = session.database else { return [] }
        return session.objects.filter { $0.kind == .table || $0.kind == .view }.map { object in
            MCPResource(uri: Self.uri(target.id, database, object.name), name: object.name,
                        description: "The \(object.kind == .view ? "view" : "table") \(database).\(object.name) on \(target.name): "
                            + "columns, indexes, foreign keys and its CREATE statement.")
        }
    }

    var resourceTemplates: [MCPResource] {
        [MCPResource(uri: "quarry://{connection}/{database}/{table}", name: "Table schema",
                     description: "A table's columns, indexes, foreign keys and CREATE statement. connection is an id from list_connections.")]
    }

    static func uri(_ connection: String, _ database: String, _ table: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return "quarry://" + [connection, database, table]
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "/")
    }

    func readResource(_ uri: String) async throws -> String {
        try await logged("resources/read", arguments: ["uri": .string(uri)]) { try await self.resource(uri) }
    }

    private func resource(_ uri: String) async throws -> String {
        guard let model else { throw MCPToolError("Quarry is closing.") }
        let parts = uri.hasPrefix("quarry://") ? uri.dropFirst(9).split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).removingPercentEncoding ?? String($0) } : []
        guard parts.count == 3, !parts.contains(where: \.isEmpty) else {
            throw MCPToolError("Quarry's resources look like quarry://{connection}/{database}/{table}.")
        }
        let target = try connections.target(parts[0], model: model)
        ActivityTrace.current?.database = parts[1]
        var schema = try await describe(parts[2], in: parts[1], target: target)
        let kind = schema["kind"]?.string ?? "table"
        let create = try? await createStatement(ToolArgs(["connection": .string(target.id), "database": .string(parts[1]),
                                                          "name": .string(parts[2]), "kind": .string(kind)]), model: model)
        if case .object(var object) = schema, let statement = create?["statement"] {
            object["createStatement"] = statement
            schema = .object(object)
        }
        return schema.text
    }

    // MARK: Completion

    func complete(argument: String, value: String, context: [String: String]) async -> [String] {
        guard let model else { return [] }
        let prefix = value.lowercased()
        func matching(_ names: [String]) -> [String] {
            names.filter { $0.lowercased().hasPrefix(prefix) }.sorted { $0.lowercased() < $1.lowercased() }
        }
        switch argument {
        case "connection":
            return matching(connections.targets(model: model).flatMap { [$0.id, $0.name] })
        case "database":
            guard let target = try? connections.target(context["connection"], model: model),
                  let names = try? await connections.run(target, { try await $0.databases() }) else { return [] }
            return matching(names)
        case "table":
            guard let target = try? connections.target(context["connection"], model: model) else { return [] }
            let database = context["database"] ?? target.session?.database ?? target.details.database
            guard !database.isEmpty,
                  let objects = try? await connections.run(target, { try await $0.tablesAndViews(in: database) }) else { return [] }
            return matching(objects.map(\.name))
        default:
            return []
        }
    }
}
