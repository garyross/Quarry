import AppKit
import QuarryKit

/// Self-test: agents on SQLite files (S-073), through the running MCP server.
extension SelfTest {
    typealias AgentToolCall = (_ name: String, _ arguments: JSONValue) async -> (ok: Bool, json: JSONValue?, text: String)

    /// Runs with the self-test's HTTP token read only; `setAccess` changes it for the write checks.
    static func mcpSQLite(model: AppModel, tool: AgentToolCall, setAccess: (AgentAccess) -> Void) async {
        guard let url = makeSQLiteFixture() else {
            return check("S-073 the SQLite fixture is made for the agent checks", false, "APP_SQLITE_FIXTURE: \(sqliteFixtureScript ?? "unset")")
        }
        // Saved with no name, so it goes by its file name.
        let uid = model.save(ConnectionDetails(transport: .sqlite, file: url.path), over: nil)
        let id = AgentConnections.shortID(uid)
        let place: JSONValue = ["connection": .string(id)]
        func with(_ extra: [String: JSONValue]) -> JSONValue {
            var arguments = extra
            arguments["connection"] = .string(id)
            return .object(arguments)
        }

        /// The first cell of a read, as text, whether it came back as a number or a string.
        func cell(_ json: JSONValue?) -> String? {
            guard let value = json?["rows"]?.array?.first?.array?.first else { return nil }
            return value.int.map(String.init) ?? value.string
        }

        let listed = await tool("list_connections", [:])
        let mine = listed.json?["connections"]?.array?.first { $0["id"] == .string(id) }
        check("S-073 list_connections lists a SQLite file with engine \"sqlite\", servers with \"mysql\"",
              mine?["engine"] == "sqlite" && mine?["name"] == "quarry_demo.sqlite"
                  && listed.json?["connections"]?.array?.contains { $0["engine"] == "mysql" } == true,
              mine?.text ?? listed.text.prefix(200).description)

        let databases = await tool("list_databases", place)
        let tables = await tool("list_tables", place)
        let names = tables.json?["tables"]?.array?.compactMap { $0["name"]?.string } ?? []
        let described = await tool("describe_table", with(["table": "orders"]))
        let routines = await tool("list_routines", place)
        let trigger = routines.json?["triggers"]?.array?.first
        let view = await tool("get_create_statement", with(["name": "order_totals"]))
        check("S-073 the schema tools work on the file: main, its tables and views, columns, indexes, foreign keys, triggers, CREATE",
              databases.json?["databases"] == ["main"] && names.contains("customers") && names.contains("order_totals")
                  && described.json?["foreignKeys"]?.array?.count == 1 && (described.json?["indexes"]?.array?.count ?? 0) >= 2
                  && trigger?["name"] == "products_stock_check" && trigger?["timing"] == "BEFORE" && trigger?["event"] == "UPDATE"
                  && view.json?["statement"]?.string?.hasPrefix("CREATE VIEW") == true,
              [databases.text, tables.text, described.text, routines.text, view.text].map { $0.prefix(120) }.joined(separator: " | "))

        let read = await tool("read_query", with(["sql": "SELECT name FROM customers WHERE country = ? ORDER BY id", "params": ["UK"]]))
        let pragma = await tool("read_query", with(["sql": "PRAGMA table_info(orders)"]))
        let queryOnly = await tool("read_query", with(["sql": "PRAGMA query_only"]))
        check("S-073 read_query reads the file, and PRAGMAs that read, on a connection with query_only",
              read.json?["rowCount"] == 2 && pragma.json?["rowCount"] == 5 && cell(queryOnly.json) == "1",
              read.text.prefix(120) + " | " + pragma.text.prefix(80) + " | " + queryOnly.text.prefix(80))

        let quoted = await tool("read_query", with(["sql": "SELECT ? || '|' || length(?)", "params": ["it's a\\b", "a\\b"]]))
        check("Agent params on a SQLite file are quoted as SQLite reads them (a quote doubled, a backslash kept as one)",
              cell(quoted.json) == "it's a\\b|3", quoted.text.prefix(160).description)

        let delete = await tool("read_query", with(["sql": "DELETE FROM notes"]))
        let attach = await tool("read_query", with(["sql": .string("ATTACH '\(url.path)' AS other")]))
        let unlock = await tool("read_query", with(["sql": "PRAGMA query_only = OFF"]))
        let extensionCall = await tool("read_query", with(["sql": "SELECT load_extension('/tmp/x')"]))
        check("S-073 read_query refuses writes, ATTACH, load_extension and PRAGMAs that write",
              !delete.ok && delete.text.contains("write_query") && !attach.ok && attach.text == AgentSQL.attachProblem
                  && !unlock.ok && !extensionCall.ok,
              [delete.text, attach.text, unlock.text, extensionCall.text].joined(separator: " | "))
        // Past the rules, SQLite itself refuses: the read connection is opened read only, with query_only.
        var refusal = ""
        if let target = try? MCPHost.shared.tools.connections.target(id, model: model) {
            do { _ = try await MCPHost.shared.tools.connections.run(target) { try await $0.run("DELETE FROM notes") } }
            catch { refusal = (error as? MCPToolError)?.message ?? "\(error)" }
        }
        check("S-073 a write on the read connection is refused by SQLite itself", refusal.localizedCaseInsensitiveContains("read"), refusal)

        let plan = await tool("explain_query", with(["sql": "SELECT * FROM orders WHERE customer_id = 1"]))
        let sample = await tool("sample_rows", with(["table": "events", "limit": 3]))
        let count = await tool("count_rows", with(["table": "events"]))
        let some = await tool("count_rows", with(["table": "events", "where": "kind = 'buy'"]))
        check("S-073 explain_query (EXPLAIN QUERY PLAN), sample_rows and count_rows",
              plan.ok && plan.text.contains("orders_customer") && sample.json?["rowCount"] == 3
                  && count.json?["rows"] == 2500 && some.json?["rows"] == 833,
              plan.text.suffix(160) + " | " + count.text + " | " + some.text)

        let sizes = await tool("table_sizes", place)
        let info = await tool("server_info", place)
        check("S-073 table_sizes from dbstat; server_info gives the SQLite version and the file's settings",
              sizes.json?["tables"]?.array?.count == 7 && (sizes.json?["totalBytes"]?.int ?? 0) > 0
                  && info.json?["server"]?.string?.hasPrefix("SQLite ") == true && info.json?["engine"] == "sqlite"
                  && info.json?["settings"]?["journal_mode"] != nil && info.json?["settings"]?["page_size"] != nil
                  && info.json?["file"] == .string(url.path) && (info.json?["bytes"]?.int ?? 0) > 0 && info.json?["user"] == nil,
              sizes.text.prefix(120) + " | " + info.text.prefix(300))

        let processes = await tool("list_processes", place)
        let kill = await tool("kill_process", with(["id": 1]))
        check("S-073 list_processes and kill_process say a file has no server processes",
              !processes.ok && processes.text == "SQLite files have no server processes." && kill.text == processes.text,
              processes.text + " | " + kill.text)

        let readOnly = await tool("write_query", with(["sql": "INSERT INTO notes VALUES (?)", "params": ["from an agent"]]))
        setAccess(.readWrite)
        let written = await tool("write_query", with(["sql": "INSERT INTO notes VALUES (?)", "params": ["from an agent"]]))
        let seen = await tool("read_query", with(["sql": "SELECT count(*) FROM notes WHERE body = 'from an agent'"]))
        let attachWrite = await tool("write_query", with(["sql": .string("ATTACH '\(url.path)' AS other")]))
        let lockedID = AgentConnections.shortID(model.save(ConnectionDetails(transport: .sqlite, file: url.path, readOnly: true), over: nil))
        let locked = await tool("write_query", ["connection": .string(lockedID), "sql": "DELETE FROM notes"])
        setAccess(.readOnly)
        check("S-073 write_query follows the token, writes the file, and still refuses ATTACH and Open Read Only files",
              !readOnly.ok && readOnly.text.contains("read only") && written.json?["affectedRows"] == 1
                  && cell(seen.json) == "1" && attachWrite.text == AgentSQL.attachProblem
                  && !locked.ok && locked.text.contains("Open Read Only"),
              [readOnly.text, written.text, seen.text.prefix(80).description, attachWrite.text, locked.text].joined(separator: " | "))

        check("S-073 MCP Activity names the file as the connection",
              model.agentActivity.contains { $0.connection == "quarry_demo.sqlite" && $0.tool == "write_query" && $0.status == .ok },
              model.agentActivity.prefix(3).map { "\($0.connection)/\($0.tool)" }.joined(separator: ", "))

        let gone = url.deletingLastPathComponent().appending(path: "gone.sqlite")
        let missingID = AgentConnections.shortID(model.save(ConnectionDetails(transport: .sqlite, file: gone.path), over: nil))
        let missing = await tool("read_query", ["connection": .string(missingID), "sql": "SELECT 1"])
        check("S-073 a missing file gives the agent S-068's words",
              !missing.ok && missing.text.hasPrefix("Can’t find “gone.sqlite”. It was moved or deleted."), missing.text)

        let closed = await tool("close_connection", place)
        let relisted = await tool("list_connections", [:])
        check("S-073 close_connection closes both of the agent's connections to the file",
              closed.json?["closed"] == true
                  && relisted.json?["connections"]?.array?.first { $0["id"] == .string(id) }?["agentConnected"] == false,
              closed.text)
        for saved in model.savedConnections() where saved.kind == .sqlite && saved.file.hasPrefix(url.deletingLastPathComponent().path) {
            model.delete(saved.uid)
        }
        model.delete(uid)
    }
}
