import AppKit
import QuarryKit

/// What agents can do through Quarry's MCP server (S-063): 19 tools over the
/// person's saved connections, plus table schemas as resources, three prompts,
/// and completion of connection, database and table names. Every tool runs on
/// the agent's own connection (`AgentConnections`), and every statement shows
/// in the Console.
@MainActor
final class AgentTools: MCPHandler {
    weak var model: AppModel?
    let connections = AgentConnections()
    /// Set by MCPHost: whether write_query and kill_process wait for Allow (S-064).
    var asksBeforeChanges: () -> Bool = { true }

    static let instructions = """
        Quarry is a MySQL, MariaDB and SQLite client on this Mac. These tools reach the person's saved Quarry connections, \
        on a connection of the agent's own, so the person's windows are never changed. Leave out connection (and \
        database) to use what the frontmost Quarry window shows; list_connections names the others and their engine. \
        read_query runs reads inside a read-only transaction. A SQLite file (engine "sqlite") has one database, main, \
        and no server processes; its reads run on a read-only connection and may use PRAGMAs that read. write_query and kill_process work only with a Read & Write token \
        (Quarry > Settings > MCP > Tokens), and the person may be asked to approve each one. Every statement shows in Quarry's Console (Shift-Command-K).
        """

    // MARK: Tools

    static let connectionParam: JSONValue = ["type": "string",
        "description": "A connection's id or name from list_connections. Leave out for the frontmost Quarry window's connection."]
    static let databaseParam: JSONValue = ["type": "string",
        "description": "The database. Leave out for the one the frontmost window shows, or the connection's default."]
    static let tableParam: JSONValue = ["type": "string", "description": "A table or view in the database."]
    static let sqlParam: JSONValue = ["type": "string", "description": "One SQL statement. Use ? for values given in params."]
    static let paramsParam: JSONValue = ["type": "array", "items": ["type": ["string", "number", "boolean", "null"]],
        "description": "Values for the ? placeholders in sql, in order; Quarry quotes them."]

    static let place: [String: JSONValue] = ["connection": connectionParam, "database": databaseParam]

    let tools: [MCPTool] = [
        MCPTool(name: "list_connections", title: "List Connections",
                description: "Lists the saved Quarry connections and connected windows: id, name, engine (mysql or sqlite), "
                    + "server or file, user, group, default database, how many windows show it, and which is frontmost."),
        MCPTool(name: "open_connection", title: "Open Connection",
                description: "Shows a connection in a new Quarry tab, so the person can see it, optionally on a database and table.",
                parameters: ["connection": ["type": "string", "description": "A connection's id or name from list_connections."],
                             "database": databaseParam, "table": tableParam],
                required: ["connection"], readOnly: false),
        MCPTool(name: "close_connection", title: "Close Connection",
                description: "Closes the agent's own connection to a server. Quarry's windows stay as they are.",
                parameters: ["connection": connectionParam], readOnly: false),
        MCPTool(name: "list_databases", title: "List Databases",
                description: "Lists the databases on a connection, and the one the frontmost window shows.",
                parameters: ["connection": connectionParam]),
        MCPTool(name: "list_tables", title: "List Tables",
                description: "Lists a database's tables and views with engine, estimated rows and comment.",
                parameters: place),
        MCPTool(name: "list_routines", title: "List Routines",
                description: "Lists a database's procedures, functions, triggers and events.",
                parameters: place),
        MCPTool(name: "describe_table", title: "Describe Table",
                description: "A table's or view's columns (type, null, key, default, extra, comment), indexes and foreign keys.",
                parameters: place.merging(["table": tableParam]) { $1 }, required: ["table"]),
        MCPTool(name: "get_create_statement", title: "Get Create Statement",
                description: "The CREATE statement for a table, view, procedure, function, trigger or event.",
                parameters: place.merging(["name": ["type": "string", "description": "The object's name."],
                                           "kind": ["type": "string", "enum": ["table", "view", "procedure", "function", "trigger", "event"],
                                                    "description": "Leave out to find it by name."]]) { $1 },
                required: ["name"]),
        MCPTool(name: "read_query", title: "Read Query",
                description: "Runs one read (SELECT, SHOW, DESCRIBE, EXPLAIN, WITH; on a SQLite file SELECT, WITH, EXPLAIN and "
                    + "PRAGMAs that read) inside a read-only transaction and returns columns and rows. limit is 100 by default, at most 10,000; pass nextOffset back as offset for more.",
                parameters: place.merging(["sql": sqlParam, "params": paramsParam,
                                           "limit": ["type": "integer", "description": "Rows to return, 1 to 10,000 (100)."],
                                           "offset": ["type": "integer", "description": "Rows to skip first (0)."]]) { $1 },
                required: ["sql"]),
        MCPTool(name: "write_query", title: "Write Query",
                description: "Runs one statement that may change data or structure (INSERT, UPDATE, DELETE, CREATE, ALTER…). "
                    + "Needs a Read & Write token; the person may be asked to approve it in Quarry first.",
                parameters: place.merging(["sql": sqlParam, "params": paramsParam]) { $1 },
                required: ["sql"], readOnly: false, destructive: true),
        MCPTool(name: "explain_query", title: "Explain Query",
                description: "The server's plan for a SELECT, UPDATE, DELETE or INSERT, without running it.",
                parameters: place.merging(["sql": sqlParam, "params": paramsParam]) { $1 }, required: ["sql"]),
        MCPTool(name: "sample_rows", title: "Sample Rows",
                description: "The first rows of a table or view, 10 by default, at most 1,000.",
                parameters: place.merging(["table": tableParam,
                                           "limit": ["type": "integer", "description": "Rows, 1 to 1,000 (10)."]]) { $1 },
                required: ["table"]),
        MCPTool(name: "count_rows", title: "Count Rows",
                description: "The exact number of rows in a table, or of those matching a WHERE condition.",
                parameters: place.merging(["table": tableParam,
                                           "where": ["type": "string", "description": "A condition without the word WHERE, such as status = 'open'."]]) { $1 },
                required: ["table"]),
        MCPTool(name: "server_info", title: "Server Info",
                description: "The server's version, the user logged in, SSL, uptime and key settings (character set, sql_mode, time zone…); "
                    + "for a SQLite file, the SQLite version, the file's size and its settings (page size, journal mode…).",
                parameters: ["connection": connectionParam]),
        MCPTool(name: "table_sizes", title: "Table Sizes",
                description: "Each table's engine, estimated rows, and data, index and free space in bytes, largest first.",
                parameters: place),
        MCPTool(name: "list_processes", title: "List Processes",
                description: "The server's connections and what each is running (SHOW PROCESSLIST).",
                parameters: ["connection": connectionParam,
                             "full": ["type": "boolean", "description": "Whole statements instead of the first 100 characters."]]),
        MCPTool(name: "kill_process", title: "Kill Process",
                description: "Stops a process's running statement (KILL QUERY), or with connection_too its whole connection. "
                    + "Needs a Read & Write token; the person may be asked to approve it in Quarry first.",
                parameters: ["connection": connectionParam,
                             "id": ["type": "integer", "description": "The process id from list_processes."],
                             "connection_too": ["type": "boolean", "description": "Also close the process's connection (KILL)."]],
                required: ["id"], readOnly: false, destructive: true),
        MCPTool(name: "list_saved_queries", title: "List Saved Queries",
                description: "The person's saved queries in Quarry, by name.",
                parameters: ["search": ["type": "string", "description": "Only those with this text in the name or query."]]),
        MCPTool(name: "query_history", title: "Query History",
                description: "Queries the person ran in Quarry on a connection's server, newest first.",
                parameters: ["connection": connectionParam,
                             "search": ["type": "string", "description": "Only queries with this text."],
                             "limit": ["type": "integer", "description": "At most this many (20)."]]),
    ]

    /// Runs a tool and keeps the request for MCP Activity (S-065).
    func callTool(_ name: String, arguments: [String: JSONValue], client: MCPClient) async throws -> JSONValue {
        try await logged(name, arguments: arguments) { try await self.run(name, arguments: arguments) }
    }

    /// Runs `work` with a trace, then logs what it touched, how long it took, and whether it worked.
    func logged<T>(_ tool: String, arguments: [String: JSONValue], _ work: () async throws -> T) async throws -> T {
        let trace = ActivityTrace()
        let started = Date.now
        let clock = ContinuousClock.now
        var status = ActivityRecord.Status.ok
        var message = ""
        defer {
            let caller = AgentCaller.current
            let elapsed = ContinuousClock.now - clock
            let statement = trace.statement.isEmpty ? AgentActivity.summary(arguments) : trace.statement
            model?.logAgentRequest(ActivityRecord(
                date: started, client: caller.client, token: caller.token, tokenID: caller.tokenID, connection: trace.connection,
                database: trace.database, tool: tool, statement: statement, status: status, message: message,
                duration: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
        }
        do {
            return try await ActivityTrace.$current.withValue(trace) { try await work() }
        } catch {
            let tool = error as? MCPToolError
            status = tool?.denied == true ? .denied : .error
            message = tool?.message ?? (error as? LocalizedError)?.errorDescription ?? "\(error)"
            throw error
        }
    }

    private func run(_ name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        guard let model else { throw MCPToolError("Quarry is closing.") }
        let args = ToolArgs(arguments)
        switch name {
        case "list_connections": return listConnections(model: model)
        case "open_connection": return try openConnection(args, model: model)
        case "close_connection": return try await closeConnection(args, model: model)
        case "list_databases": return try await listDatabases(args, model: model)
        case "list_tables": return try await listTables(args, model: model)
        case "list_routines": return try await listRoutines(args, model: model)
        case "describe_table": return try await describeTable(args, model: model)
        case "get_create_statement": return try await createStatement(args, model: model)
        case "read_query": return try await readQuery(args, model: model)
        case "write_query": return try await writeQuery(args, model: model)
        case "explain_query": return try await explainQuery(args, model: model)
        case "sample_rows": return try await sampleRows(args, model: model)
        case "count_rows": return try await countRows(args, model: model)
        case "server_info": return try await serverInfo(args, model: model)
        case "table_sizes": return try await tableSizes(args, model: model)
        case "list_processes": return try await listProcesses(args, model: model)
        case "kill_process": return try await killProcess(args, model: model)
        case "list_saved_queries": return listSavedQueries(args, model: model)
        case "query_history": return try queryHistory(args, model: model)
        default: throw MCPToolError("No tool named \(name).")
        }
    }

    // MARK: Shared

    /// The database a tool works in: the one passed, else the window's, else the connection's default.
    func database(_ args: ToolArgs, _ target: AgentConnections.Target) throws -> String {
        // A SQLite file has one database, main (S-073).
        let fallback = target.details.engine == .sqlite ? SQLiteDialect.mainDatabase : target.details.database.trimmingCharacters(in: .whitespaces)
        if let name = args.string("database") ?? target.session?.database ?? (fallback.isEmpty ? nil : fallback) {
            ActivityTrace.current?.database = name
            return name
        }
        throw MCPToolError("Pass database: \(target.name) has none chosen. Run list_databases to see them.")
    }

    /// The database when one is known, else nil (read_query works without one).
    func optionalDatabase(_ args: ToolArgs, _ target: AgentConnections.Target) -> String? {
        try? database(args, target)
    }

    /// Rows of a schema query as objects, keyed by the given column names.
    static func records(_ result: StatementResult, _ keys: [String: String]) -> [JSONValue] {
        result.rows.indices.map { row in
            .object(keys.mapValues { column in .optional(result.string(row, column)) })
        }
    }

    // MARK: Connections

    func listConnections(model: AppModel) -> JSONValue {
        let groups = Dictionary(model.connectionGroups().map { ($0.uid, $0.name) }, uniquingKeysWith: { first, _ in first })
        let saved = Dictionary(model.savedConnections().map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let front = try? connections.target(nil, model: model)
        let list: [JSONValue] = connections.targets(model: model).map { target in
            let connection = target.savedUID.flatMap { saved[$0] }
            var item: [String: JSONValue] = [
                "id": .string(target.id), "name": .string(target.name), "engine": .string(target.details.engine.rawValue),
                "server": .string(target.details.summary),
                "user": .string(target.details.user), "saved": .bool(target.savedUID != nil),
                "openInWindows": .int(target.savedUID.map { AgentConnections.windows(for: $0).count } ?? 1),
                "agentConnected": .bool(connections.isOpen(target.id)),
            ]
            let fallback = target.details.database.trimmingCharacters(in: .whitespaces)
            if !fallback.isEmpty { item["defaultDatabase"] = .string(fallback) }
            if let group = connection?.groupID.flatMap({ groups[$0] }) { item["group"] = .string(group) }
            if let session = target.session, let database = session.database { item["windowDatabase"] = .string(database) }
            if target.id == front?.id { item["frontmost"] = true }
            return .object(item)
        }
        return ["connections": .array(list)]
    }

    func openConnection(_ args: ToolArgs, model: AppModel) throws -> JSONValue {
        let target = try connections.target(try args.required("connection"), model: model)
        guard Tabs.openWindow != nil else { throw MCPToolError("Quarry has no window to open a tab beside. Open one first.") }
        var details = target.details
        if let uid = target.savedUID, details.password.isEmpty { PasswordStore.fill(&details, from: uid) }
        let database = args.string("database")
        let table = args.string("table")
        if table != nil, database == nil, target.details.database.trimmingCharacters(in: .whitespaces).isEmpty {
            throw MCPToolError("Pass database with table.")
        }
        let uid = target.savedUID
        Tabs.open(beside: NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }) { tab, model in
            tab.form = details
            if let database { tab.form.database = database }
            tab.selectedSaved = uid
            if let table {
                tab.pendingPlace = Session.Place(database: database ?? details.database, objectID: DBObject(name: table, kind: .table).id,
                                                 view: .content, content: nil)
            }
            tab.connect(model: model)
        }
        return ["opening": true, "connection": .string(target.id), "name": .string(target.name)]
    }

    func closeConnection(_ args: ToolArgs, model: AppModel) async throws -> JSONValue {
        let target = try connections.target(args.string("connection"), model: model)
        let closed = await connections.close(target.id)
        return ["closed": .bool(closed), "connection": .string(target.id),
                "note": .string(closed ? "Closed the agent's connection. Quarry's windows are unchanged."
                    : "The agent had no connection open to \(target.name).")]
    }
}

/// A tool's arguments, read with checks that say how to fix a bad one.
struct ToolArgs {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) { self.values = values }

    /// Text, trimmed; nil when missing or empty.
    func string(_ name: String) -> String? {
        guard let value = values[name] else { return nil }
        let text = (value.string ?? (value.int.map(String.init) ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func required(_ name: String) throws -> String {
        guard let text = string(name) else { throw MCPToolError("Pass \(name).") }
        return text
    }

    func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws -> Int {
        guard let value = values[name], !value.isNull else { return fallback }
        guard let number = value.int else { throw MCPToolError("\(name) must be a whole number.") }
        guard range.contains(number) else {
            throw MCPToolError("\(name) must be from \(range.lowerBound.formatted()) to \(range.upperBound.formatted()).")
        }
        return number
    }

    func bool(_ name: String) -> Bool { values[name]?.bool ?? false }

    /// The ? values; strings, numbers, booleans and null.
    var params: [JSONValue] {
        get throws {
            guard let value = values["params"], !value.isNull else { return [] }
            guard let list = value.array else { throw MCPToolError("params must be a list of values.") }
            return list
        }
    }

    /// `sql` with params filled in, quoted as `engine` reads them.
    func boundSQL(engine: Engine) throws -> String {
        do {
            let sql = try AgentSQL.bind(try required("sql"), try params, engine: engine)
            ActivityTrace.current?.statement = sql
            return sql
        } catch let error as AgentSQL.BindError {
            throw MCPToolError(error.message)
        }
    }
}
