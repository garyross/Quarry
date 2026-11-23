import Foundation
import QuarryKit

/// Query, server and Quarry-data tools, and the prompts (S-063).
extension AgentTools {
    static let maxRows = 10_000

    func readQuery(_ args: ToolArgs, model: AppModel) async throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        let sql = try args.boundSQL(engine: target.details.engine)
        if let problem = AgentSQL.readProblem(sql, engine: target.details.engine) { throw MCPToolError(problem) }
        let limit = try args.int("limit", default: 100, in: 1...Self.maxRows)
        let offset = try args.int("offset", default: 0, in: 0...Int.max)
        let database = optionalDatabase(args, target)
        let rows = try await connections.run(target) { try await $0.agentRead(sql, in: database, offset: offset, limit: limit) }
        return Self.withDatabase(rows.json(offset: offset), database)
    }

    func writeQuery(_ args: ToolArgs, model: AppModel) async throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        try checkWrite(target)
        if target.details.engine == .sqlite, target.details.readOnly {
            throw MCPToolError("\(target.name) opens with Open Read Only in Quarry, so nothing can change it. "
                + "The person can turn that off in the connection.")
        }
        let sql = try args.boundSQL(engine: target.details.engine)
        if let problem = AgentSQL.statementProblem(sql, engine: target.details.engine) { throw MCPToolError(problem) }
        let database = optionalDatabase(args, target)
        try await approve(target, database: database, statement: sql)
        let rows = try await connections.run(target, writes: true) { try await $0.agentWrite(sql, in: database) }
        return Self.withDatabase(rows.json(offset: 0), database)
    }

    func explainQuery(_ args: ToolArgs, model: AppModel) async throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        let sql = try args.boundSQL(engine: target.details.engine)
        if let problem = AgentSQL.statementProblem(sql, engine: target.details.engine) { throw MCPToolError(problem) }
        let explainable: Set<String> = ["SELECT", "WITH", "UPDATE", "DELETE", "INSERT", "REPLACE", "TABLE", "VALUES"]
        guard let first = AgentSQL.firstKeyword(sql), explainable.contains(first) else {
            throw MCPToolError("explain_query explains SELECT, UPDATE, DELETE, INSERT and REPLACE statements.")
        }
        let database = optionalDatabase(args, target)
        let rows = try await connections.run(target) { try await $0.agentRead($0.dialect.explainSQL(sql), in: database, offset: 0, limit: 1000) }
        return Self.withDatabase(rows.json(offset: 0), database)
    }

    func sampleRows(_ args: ToolArgs, model: AppModel) async throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        let database = try database(args, target)
        let table = try args.required("table")
        let limit = try args.int("limit", default: 10, in: 1...1000)
        let rows = try await connections.run(target) {
            try await $0.agentRead($0.dialect.sampleSQL(table: table, database: database, limit: limit), in: nil, offset: 0, limit: limit)
        }
        return Self.withDatabase(rows.json(offset: 0), database)
    }

    func countRows(_ args: ToolArgs, model: AppModel) async throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        let database = try database(args, target)
        let table = try args.required("table")
        let condition = args.string("where")
        let rows = try await connections.run(target) { client in
            let sql = client.dialect.countSQL(table: table, database: database, where: condition)
            if let problem = AgentSQL.readProblem(sql, engine: client.dialect.engine) { throw MCPToolError(problem) }
            return try await client.agentRead(sql, in: database, offset: 0, limit: 1)
        }
        let count = rows.rows.first?.first?.plainText.flatMap(Int.init) ?? 0
        var result: [String: JSONValue] = ["database": .string(database), "table": .string(table), "rows": .int(count)]
        if let condition = args.string("where") { result["where"] = .string(condition) }
        return .object(result)
    }

    static func withDatabase(_ json: JSONValue, _ database: String?) -> JSONValue {
        guard case .object(var object) = json, let database else { return json }
        object["database"] = .string(database)
        return .object(object)
    }

    // MARK: Server

    nonisolated static let keyVariables = ["version_comment", "character_set_server", "collation_server", "character_set_database",
                               "time_zone", "system_time_zone", "sql_mode", "max_connections", "max_allowed_packet",
                               "default_storage_engine", "innodb_buffer_pool_size", "lower_case_table_names", "read_only",
                               "wait_timeout", "hostname", "port"]

    func serverInfo(_ args: ToolArgs, model: AppModel) async throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        let (client, user, variables, uptime) = try await connections.run(target) { client in
            let dialect = client.dialect
            var user: String?
            if let sql = dialect.currentUserSQL { user = try await client.run(sql).rows.first?.first?.plainText }
            var variables: StatementResult?
            // A SQLite file has settings of its own instead of server variables (S-073).
            if let sql = dialect.variablesSQL(named: Self.keyVariables) ?? dialect.fileSettingsSQL { variables = try await client.run(sql) }
            var uptime: StatementResult?
            if let sql = dialect.uptimeSQL { uptime = try? await client.run(sql) }
            return (client, user, variables, uptime)
        }
        var settings: [String: JSONValue] = [:]
        if let variables {
            for row in variables.rows.indices {
                if let name = variables.string(row, "Variable_name") { settings[name] = .optional(variables.string(row, "Value")) }
            }
        }
        var result: [String: JSONValue] = ["connection": .string(target.id), "server": .string(client.serverDescription),
                                           "version": .string(client.serverVersion), "user": .optional(user),
                                           "variables": .object(settings)]
        if let seconds = uptime?.string(0, "Value").flatMap(Int.init) { result["uptimeSeconds"] = .int(seconds) }
        if target.details.engine == .sqlite { return Self.fileInfo(result, target: target) }
        if let encryption = client.encryption {
            result["ssl"] = ["version": .string(encryption.version), "cipher": .string(encryption.cipher)]
        } else {
            result["ssl"] = .null
        }
        return .object(result)
    }

    /// server_info for a SQLite file: no user, uptime or SSL; the file, its size and its settings.
    static func fileInfo(_ server: [String: JSONValue], target: AgentConnections.Target) -> JSONValue {
        var result = server
        result["user"] = nil
        result["settings"] = result.removeValue(forKey: "variables")
        result["engine"] = "sqlite"
        if let url = target.details.fileURL {
            result["file"] = .string(url.path)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            result["bytes"] = .int(bytes)
            result["size"] = .string(ByteCount.format(bytes))
        }
        result["openReadOnly"] = .bool(target.details.readOnly)
        return .object(result)
    }

    func tableSizes(_ args: ToolArgs, model: AppModel) async throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        let database = try database(args, target)
        let result = try await connections.run(target) { client in
            let dialect = client.dialect
            // A SQLite built without dbstat gives the names alone.
            guard let fallback = dialect.tableSizesFallbackSQL(in: database) else { return try await client.run(dialect.tableSizesSQL(in: database)) }
            do { return try await client.run(dialect.tableSizesSQL(in: database)) } catch { return try await client.run(fallback) }
        }
        var total = 0
        let tables: [JSONValue] = result.rows.indices.map { row in
            let data = result.string(row, "data").flatMap(Int.init) ?? 0
            let index = result.string(row, "idx").flatMap(Int.init) ?? 0
            total += data + index
            return ["name": .optional(result.string(row, "name")), "engine": .optional(result.string(row, "engine")),
                    "rowsEstimate": .optional(result.string(row, "rows_estimate").flatMap(Int.init)),
                    "dataBytes": .int(data), "indexBytes": .int(index),
                    "freeBytes": .int(result.string(row, "free").flatMap(Int.init) ?? 0),
                    "size": .string(ByteCount.format(data + index))]
        }
        return ["database": .string(database), "tables": .array(tables), "totalBytes": .int(total), "total": .string(ByteCount.format(total))]
    }

    func listProcesses(_ args: ToolArgs, model: AppModel) async throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        if target.details.engine == .sqlite { throw MCPToolError(Self.noFileProcesses) }
        let full = args.bool("full")
        let (result, own) = try await connections.run(target) { client in
            guard let sql = client.dialect.processListSQL(full: full) else { throw MCPToolError(Self.noProcesses) }
            return (try await client.run(sql), client.connectionID)
        }
        let processes: [JSONValue] = ServerProcess.processes(result).map { process in
            var item: [String: JSONValue] = ["id": .int(Int(process.id)), "user": .string(process.user), "host": .string(process.host),
                                             "database": .optional(process.database), "command": .string(process.command),
                                             "seconds": .int(process.time), "state": .string(process.state),
                                             "statement": .optional(process.info)]
            if Int(process.id) == own { item["agent"] = true }
            return .object(item)
        }
        return ["connection": .string(target.id), "processes": .array(processes)]
    }

    func killProcess(_ args: ToolArgs, model: AppModel) async throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        if target.details.engine == .sqlite { throw MCPToolError(Self.noFileProcesses) }
        try checkWrite(target)
        let id = try args.int("id", default: -1, in: 0...Int.max)
        guard id >= 0 else { throw MCPToolError("Pass id, a process id from list_processes.") }
        let whole = args.bool("connection_too")
        let kill = try await connections.run(target) { $0.dialect.killSQL(id, connection: whole) }
        guard let sql = kill else { throw MCPToolError(Self.noProcesses) }
        ActivityTrace.current?.statement = sql
        try await approve(target, database: nil, statement: sql)
        _ = try await connections.run(target) { try await $0.run(sql) }
        return ["killed": .int(id), "what": .string(whole ? "connection" : "query")]
    }

    /// What list_processes and kill_process say on an engine with no server processes.
    nonisolated static let noProcesses = "This connection has no server processes."
    /// The same for a SQLite file (S-073).
    nonisolated static let noFileProcesses = "SQLite files have no server processes."

    // MARK: Changes (S-064)

    /// Refuses unless the calling token may change `target`.
    func checkWrite(_ target: AgentConnections.Target) throws {
        guard connections.level(target) == .write else {
            throw MCPToolError("This token is read only on \(target.name). The person can change it in Quarry > Settings > MCP > Tokens. "
                + "Until then, use read_query.", denied: true)
        }
    }

    /// With Ask before changes on, waits for the person to click Allow.
    func approve(_ target: AgentConnections.Target, database: String?, statement: String) async throws {
        guard asksBeforeChanges() else { return }
        switch await AgentApprovals.ask(target, database: database, statement: statement) {
        case .allowed: return
        case .denied: throw MCPToolError("The person denied this change.", denied: true)
        case .timedOut: throw MCPToolError("No one answered in 2 minutes, so the change wasn’t made.", denied: true)
        }
    }

    // MARK: Quarry's own data

    func listSavedQueries(_ args: ToolArgs, model: AppModel) -> JSONValue {
        let search = args.string("search")?.lowercased()
        let queries = model.savedQueries.filter { query in
            guard let search else { return true }
            return query.name.lowercased().contains(search) || query.text.lowercased().contains(search)
        }
        return ["savedQueries": .array(queries.map { ["name": .string($0.name), "sql": .string($0.text),
                                                      "updated": .string($0.updatedAt.formatted(.iso8601))] })]
    }

    func queryHistory(_ args: ToolArgs, model: AppModel) throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        let limit = try args.int("limit", default: 20, in: 1...100)
        let search = args.string("search")?.lowercased()
        let entries = model.history(for: FavoriteDatabase.serverKey(for: target.details))
            .filter { search == nil || $0.text.lowercased().contains(search!) }
            .prefix(limit)
        return ["connection": .string(target.id),
                "history": .array(entries.map { entry in
                    ["sql": .string(entry.text), "database": entry.database.isEmpty ? .null : .string(entry.database),
                     "ran": .string(entry.ranAt.formatted(.iso8601))]
                })]
    }

    // MARK: Prompts

    var prompts: [MCPPrompt] {
        let place = [MCPPrompt.Argument(name: "connection", description: "A connection's id or name; the frontmost window's when left out."),
                     MCPPrompt.Argument(name: "database", description: "The database; the window's when left out.")]
        return [
            MCPPrompt(name: "analyze_schema", title: "Analyze Schema",
                      description: "Review a database's tables, how they relate, and what looks wrong.", arguments: place),
            MCPPrompt(name: "summarize_table", title: "Summarize Table",
                      description: "Explain what a table holds, from its structure and a few rows.",
                      arguments: [MCPPrompt.Argument(name: "table", description: "The table.", required: true)] + place),
            MCPPrompt(name: "optimize_query", title: "Optimize Query",
                      description: "Find why a query is slow and how to speed it up, without changing anything.",
                      arguments: [MCPPrompt.Argument(name: "sql", description: "The query.", required: true)] + place),
        ]
    }

    func prompt(_ name: String, arguments: [String: String]) throws -> String {
        var place = ""
        if let database = arguments["database"], !database.isEmpty { place += " database \(database)" } else { place += " the database" }
        if let connection = arguments["connection"], !connection.isEmpty { place += " on the Quarry connection \(connection)" }
        else { place += " shown in the frontmost Quarry window" }
        switch name {
        case "analyze_schema":
            return "Review the schema of\(place). Use list_tables, describe_table for each table, and table_sizes. "
                + "Summarize what the tables hold and how they relate through foreign keys, then list problems: tables "
                + "without a primary key, foreign keys without an index, columns that hold the same thing under different "
                + "types, and on MySQL or MariaDB latin1 or utf8mb3 text, MyISAM tables, and auto-increment columns close "
                + "to their limit. Don't change anything."
        case "summarize_table":
            guard let table = arguments["table"], !table.isEmpty else { throw MCPToolError("Pass table.") }
            return "Explain what the table \(table) in\(place) holds. Use describe_table, sample_rows and count_rows, "
                + "and describe_table on the tables its foreign keys point to. Say what one row means, which columns "
                + "matter most, and anything surprising in the sample. Don't change anything."
        case "optimize_query":
            guard let sql = arguments["sql"], !sql.isEmpty else { throw MCPToolError("Pass sql.") }
            return "This query runs on\(place):\n\n\(sql)\n\nUse explain_query on it, and describe_table and table_sizes "
                + "on the tables it reads. Explain what makes it slow, then suggest a rewrite or the CREATE INDEX "
                + "statements that would help, with why. Don't run any change."
        default:
            throw MCPToolError("No prompt named \(name).")
        }
    }
}
