import AppKit
import QuarryKit

/// Self-test: the MCP server (S-063), over HTTP and through the `Quarry mcp` bridge.
extension SelfTest {
    static func mcpServer(model: AppModel, session: Session) async {
        if session.phase != .connected {
            session.form = SeedData.local
            session.connect(model: model)
            await session.waitForConnect()
        }
        if session.database != "quarry_demo" { session.database = "quarry_demo" }
        await until { session.objects.contains { $0.name == "customers" } }

        let host = MCPHost.shared
        host.askOverride = false
        // S-064: an HTTP token of the test's own, read only to start with.
        let (httpToken, token) = model.createAgentToken(name: "Self-test", access: .readOnly)
        await host.start(port: 0)
        guard let port = host.port else { return check("S-063 the MCP server starts", false, host.statusText) }
        check("S-063 the server listens on 127.0.0.1 and on a socket only this user can open",
              FileManager.default.fileExists(atPath: MCPHost.socketPath)
                  && (try? FileManager.default.attributesOfItem(atPath: MCPHost.socketPath)[.posixPermissions] as? Int) == 0o600,
              host.statusText)

        let hello: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "selftest", "version": "1"]]]
        let refused = await post(port, hello, token: nil)
        let wrongOrigin = await post(port, hello, token: token, origin: "https://example.com")
        check("S-063 HTTP refuses a request without the token, and one from a web page",
              refused.status == 401 && wrongOrigin.status == 403, "\(refused.status) \(wrongOrigin.status)")
        let opened = await post(port, hello, token: token)
        check("S-063 initialize answers as quarry and starts an HTTP session",
              opened.json?["result"]?["serverInfo"]?["name"] == "quarry" && opened.session != nil,
              opened.json?.text ?? "status \(opened.status)")
        let sid = opened.session
        let note = await post(port, ["jsonrpc": "2.0", "method": "notifications/initialized"], token: token, session: sid)
        check("S-063 a notification gets 202 and no body", note.status == 202, "\(note.status)")
        await until { host.clients.contains { $0.name == "selftest" } }
        check("S-063 Settings lists the connected agent", host.clients.contains { $0.displayName == "selftest 1" } && host.statusText.contains("1 agent"),
              host.statusText)

        var nextID = 10
        func tool(_ name: String, _ arguments: JSONValue = [:]) async -> (ok: Bool, json: JSONValue?, text: String) {
            nextID += 1
            let reply = await post(port, ["jsonrpc": "2.0", "id": .int(nextID), "method": "tools/call",
                                          "params": ["name": .string(name), "arguments": arguments]], token: token, session: sid)
            let text = reply.json?["result"]?["content"]?.array?.first?["text"]?.string ?? reply.json?.text ?? ""
            return (reply.json?["result"]?["isError"] == false, JSONValue.parse(Data(text.utf8)), text)
        }
        func rpc(_ method: String, _ params: JSONValue = [:]) async -> JSONValue? {
            nextID += 1
            return await post(port, ["jsonrpc": "2.0", "id": .int(nextID), "method": .string(method), "params": params],
                              token: token, session: sid).json?["result"]
        }

        let tools = await rpc("tools/list")?["tools"]?.array ?? []
        let annotations = Dictionary(tools.compactMap { tool in tool["name"]?.string.map { ($0, tool["annotations"]) } },
                                     uniquingKeysWith: { first, _ in first })
        check("S-063 tools/list has the 19 tools, reads marked read-only and writes destructive",
              tools.count == 19 && annotations["read_query"]??["readOnlyHint"] == true
                  && annotations["write_query"]??["destructiveHint"] == true && annotations["kill_process"]??["readOnlyHint"] == false,
              "\(tools.count) tools")

        // A saved connection of its own, so its id is known.
        var details = SeedData.local
        details.name = "MCP Local"
        let uid = model.save(details, over: nil)
        let id = AgentConnections.shortID(uid)
        let connections = await tool("list_connections")
        let list = connections.json?["connections"]?.array ?? []
        check("S-063 list_connections lists saved connections with ids, and marks the frontmost window's",
              list.contains { $0["id"] == .string(id) && $0["name"] == "MCP Local" && $0["server"] == "quarry@127.0.0.1:3399" }
                  && list.contains { $0["frontmost"] == true },
              connections.text.prefix(300).description)

        let databases = await tool("list_databases")
        check("S-063 without connection, tools use the frontmost window's connection",
              databases.ok && databases.json?["databases"]?.array?.contains("quarry_demo") == true
                  && databases.json?["windowDatabase"] == "quarry_demo", databases.text.prefix(200).description)
        let tables = await tool("list_tables", ["connection": .string(id), "database": "quarry_demo"])
        let tableList = tables.json?["tables"]?.array ?? []
        check("S-063 list_tables gives tables and views by name",
              tableList.contains { $0["name"] == "customers" && $0["kind"] == "table" }
                  && tableList.contains { $0["name"] == "order_totals" && $0["kind"] == "view" }, tables.text.prefix(200).description)
        let routines = await tool("list_routines", ["connection": "MCP Local", "database": "quarry_demo"])
        check("S-063 list_routines gives procedures, functions and triggers, and a connection can be named",
              routines.json?["procedures"]?.array?.contains { $0["name"] == "customer_orders" } == true
                  && routines.json?["functions"]?.array?.contains { $0["name"] == "order_count" } == true
                  && routines.json?["triggers"]?.array?.contains { $0["name"] == "orders_before_update" && $0["table"] == "orders" } == true,
              routines.text.prefix(300).description)
        let described = await tool("describe_table", ["table": "orders"])
        check("S-063 describe_table gives columns, indexes and foreign keys",
              described.json?["columns"]?.array?.contains { $0["name"] == "id" && $0["key"] == "PRI" } == true
                  && described.json?["indexes"]?.array?.contains { $0["name"] == "PRIMARY" && $0["unique"] == true } == true
                  && described.json?["foreignKeys"]?.array?.contains { $0["references"]?.string?.hasPrefix("customers(") == true } == true,
              described.text.prefix(300).description)
        let view = await tool("get_create_statement", ["name": "order_totals"])
        let trigger = await tool("get_create_statement", ["name": "orders_before_update"])
        check("S-063 get_create_statement finds the kind by name: a view, a trigger",
              view.json?["kind"] == "view" && view.json?["statement"]?.string?.contains("VIEW") == true
                  && trigger.json?["kind"] == "trigger" && trigger.json?["statement"]?.string?.contains("TRIGGER") == true,
              view.text.prefix(120) + " | " + trigger.text.prefix(120))

        let bound = await tool("read_query", ["sql": "SELECT id, name FROM customers WHERE id = ?", "params": [1]])
        check("S-063 read_query fills ? from params and returns columns and rows",
              bound.json?["rowCount"] == 1 && bound.json?["columns"]?.array?.first?["name"] == "id"
                  && bound.json?["rows"]?.array?.first?.array?.first == 1, bound.text.prefix(200).description)
        let paged = await tool("read_query", ["sql": "SELECT id FROM events ORDER BY id", "limit": 5, "offset": 10])
        check("S-063 read_query pages: limit, offset, total rows and the next offset",
              paged.json?["rowCount"] == 5 && paged.json?["totalRows"] == 100_000 && paged.json?["nextOffset"] == 15
                  && paged.json?["rows"]?.array?.first == [11], paged.text.prefix(200).description)
        let delete = await tool("read_query", ["sql": "DELETE FROM customers"])
        let stacked = await tool("read_query", ["sql": "SELECT 1; DROP TABLE customers"])
        check("S-063 read_query refuses writes and stacked statements, saying what to use",
              !delete.ok && delete.text.contains("write_query") && !stacked.ok && stacked.text.contains("one statement"),
              delete.text + " | " + stacked.text)

        // A function that writes: the read-only transaction stops it on the server.
        _ = try? await session.client?.run("DROP TABLE IF EXISTS quarry_demo.mcp_scratch")
        _ = try? await session.client?.run("DROP FUNCTION IF EXISTS quarry_demo.mcp_writes")
        _ = try? await session.client?.run("CREATE TABLE quarry_demo.mcp_scratch (id INT)")
        _ = try? await session.client?.run("CREATE FUNCTION quarry_demo.mcp_writes() RETURNS INT MODIFIES SQL DATA "
            + "BEGIN INSERT INTO quarry_demo.mcp_scratch VALUES (1); RETURN 1; END")
        let sneaky = await tool("read_query", ["sql": "SELECT quarry_demo.mcp_writes()"])
        let scratch = await firstValue(in: session, "SELECT COUNT(*) FROM quarry_demo.mcp_scratch")
        check("S-063 a read that calls a function that writes is refused by the server",
              !sneaky.ok && scratch == "0", sneaky.text + " rows: \(scratch ?? "?")")

        let off = await tool("write_query", ["sql": "INSERT INTO quarry_demo.mcp_scratch VALUES (?)", "params": [5]])
        model.updateAgentToken(httpToken, name: httpToken.name, access: .readWrite)
        let on = await tool("write_query", ["sql": "INSERT INTO quarry_demo.mcp_scratch VALUES (?)", "params": [5]])
        check("S-063 write_query runs only with a Read & Write token, and reports rows changed",
              !off.ok && off.text.contains("read only") && on.ok && on.json?["affectedRows"] == 1,
              off.text + " | " + on.text)

        let plan = await tool("explain_query", ["sql": "SELECT * FROM customers WHERE id = 1"])
        let notPlan = await tool("explain_query", ["sql": "DROP TABLE customers"])
        check("S-063 explain_query explains a SELECT and refuses other statements",
              plan.ok && (plan.json?["rowCount"]?.int ?? 0) >= 1 && !notPlan.ok, plan.text.prefix(150) + " | " + notPlan.text)
        let sample = await tool("sample_rows", ["table": "customers", "limit": 3])
        let count = await tool("count_rows", ["table": "events"])
        let some = await tool("count_rows", ["table": "events", "where": "id <= 10"])
        check("S-063 sample_rows and count_rows",
              sample.json?["rowCount"] == 3 && count.json?["rows"] == 100_000 && some.json?["rows"] == 10,
              sample.text.prefix(80) + " | " + count.text + " | " + some.text)
        let info = await tool("server_info")
        let sizes = await tool("table_sizes")
        check("S-063 server_info and table_sizes",
              info.json?["version"]?.string?.isEmpty == false && info.json?["variables"]?["character_set_server"] != nil
                  && info.json?["user"]?.string?.hasPrefix("quarry@") == true
                  && (sizes.json?["tables"]?.array?.count ?? 0) > 3 && (sizes.json?["totalBytes"]?.int ?? 0) > 0,
              info.text.prefix(200) + " | " + sizes.text.prefix(100))

        // A second connection to stop with kill_process.
        let victim = try? await DatabaseClient.connect(SeedData.local)
        let processes = await tool("list_processes")
        check("S-063 list_processes lists connections and marks the agent's own",
              processes.json?["processes"]?.array?.contains { $0["agent"] == true } == true
                  && processes.json?["processes"]?.array?.contains { $0["id"]?.int == victim?.connectionID } == true,
              processes.text.prefix(200).description)
        if let victim, let victimID = victim.connectionID {
            let killed = await tool("kill_process", ["id": .int(victimID), "connection_too": true])
            let after = try? await victim.run("SELECT 1")
            check("S-063 kill_process ends another connection", killed.ok && after == nil, killed.text)
            await victim.close()
        }
        model.updateAgentToken(httpToken, name: httpToken.name, access: .readOnly)
        let blocked = await tool("kill_process", ["id": 1])
        check("S-063 kill_process needs a Read & Write token", !blocked.ok && blocked.text.contains("read only"), blocked.text)

        let saved = await tool("list_saved_queries")
        let history = await tool("query_history", ["limit": 5])
        check("S-063 list_saved_queries and query_history read Quarry's own data",
              saved.json?["savedQueries"]?.array?.count == model.savedQueries.count
                  && (history.json?["history"]?.array?.count ?? 99) <= 5 && history.ok,
              saved.text.prefix(100) + " | " + history.text.prefix(100))
        check("S-063 agent statements show in the Console under the connection's name and (agent)",
              ConsoleLog.shared.messages.contains { $0.connection.hasSuffix("(agent)") && $0.text.contains("mcp_scratch") })

        let resources = await rpc("resources/list")?["resources"]?.array ?? []
        let customers = resources.first { $0["name"] == "customers" }?["uri"]?.string ?? ""
        let read = await rpc("resources/read", ["uri": .string(customers)])
        let schema = read?["contents"]?.array?.first?["text"]?.string.flatMap { JSONValue.parse(Data($0.utf8)) }
        check("S-063 the frontmost window's tables are resources with their schema and CREATE statement",
              customers.hasPrefix("quarry://") && schema?["columns"]?.array?.isEmpty == false
                  && schema?["createStatement"]?.string?.hasPrefix("CREATE TABLE") == true, customers)
        let prompts = await rpc("prompts/list")?["prompts"]?.array ?? []
        let optimize = await rpc("prompts/get", ["name": "optimize_query", "arguments": ["sql": "SELECT * FROM events WHERE kind = 'x'"]])
        check("S-063 three prompts; optimize_query puts the SQL in its text",
              prompts.count == 3 && optimize?["messages"]?.array?.first?["content"]?["text"]?.string?.contains("WHERE kind = 'x'") == true)
        let completion = await rpc("completion/complete", ["ref": ["type": "ref/prompt", "name": "analyze_schema"],
                                                          "argument": ["name": "database", "value": "quarry_d"],
                                                          "context": ["arguments": ["connection": .string(id)]]])
        check("S-063 completion suggests database names", completion?["completion"]?["values"]?.array?.contains("quarry_demo") == true,
              completion?.text ?? "nil")

        // The query timeout: KILL QUERY after the limit.
        if let target = try? host.tools.connections.target(id, model: model) {
            let clock = ContinuousClock()
            let start = clock.now
            var message = ""
            do { _ = try await host.tools.connections.run(target, timeout: 1) { try await $0.run("SELECT SLEEP(10)") } }
            catch { message = (error as? MCPToolError)?.message ?? "\(error)" }
            check("S-063 a query past the time limit is stopped and says so",
                  message.contains("longer than 1 seconds") && clock.now - start < .seconds(5), message)
        }

        let closed = await tool("close_connection", ["connection": .string(id)])
        let relisted = await tool("list_connections")
        check("S-063 close_connection closes the agent's own connection",
              closed.json?["closed"] == true
                  && relisted.json?["connections"]?.array?.first { $0["id"] == .string(id) }?["agentConnected"] == false,
              closed.text)

        // open_connection: a new tab the person can see, on the table.
        let before = Tabs.lastOpened
        let open = await tool("open_connection", ["connection": .string(id), "database": "quarry_demo", "table": "products"])
        let tab = await openedTab(after: before)
        await tab?.waitForConnect()
        await until { tab?.selectedObjectID == "table:products" }
        check("S-063 open_connection opens a tab on the database and table",
              open.ok && tab?.phase == .connected && tab?.selectedObjectID == "table:products", open.text)
        if let tab { closeTab(tab) }
        session.window?.makeKeyAndOrderFront(nil)
        MenuState.shared.activate(session)

        await mcpSQLite(model: model, tool: tool) { model.updateAgentToken(httpToken, name: httpToken.name, access: $0) }
        await bridge()
        await tokens(model: model, session: session, port: port, saved: uid, value: token, token: httpToken)
        await activity(model: model, port: port, value: token)

        _ = try? await session.client?.run("DROP FUNCTION IF EXISTS quarry_demo.mcp_writes")
        _ = try? await session.client?.run("DROP TABLE IF EXISTS quarry_demo.mcp_scratch")
        _ = await post(port, .null, token: token, session: sid, method: "DELETE")
        await host.stop()
        check("S-063 stopping the server closes the socket and the agent's connections",
              host.status == .off && !FileManager.default.fileExists(atPath: MCPHost.socketPath) && host.clients.isEmpty)
        host.askOverride = nil
        model.deleteAgentToken(httpToken)
        model.delete(uid)
    }

    /// S-064: tokens with their own permission and connections, revoking and deleting, and Approve Agent Change.
    private static func tokens(model: AppModel, session: Session, port: Int, saved uid: UUID, value: String, token: AgentToken) async {
        let host = MCPHost.shared
        let id = AgentConnections.shortID(uid)
        var nextID = 1000
        func call(_ value: String, _ name: String, _ arguments: JSONValue = [:]) async -> (status: Int, ok: Bool, text: String) {
            nextID += 1
            let reply = await post(port, ["jsonrpc": "2.0", "id": .int(nextID), "method": "tools/call",
                                          "params": ["name": .string(name), "arguments": arguments]], token: value)
            let text = reply.json?["result"]?["content"]?.array?.first?["text"]?.string ?? reply.json?.text ?? ""
            return (reply.status, reply.json?["result"]?["isError"] == false, text)
        }

        check("S-064 the Automatic token comes first, for stdio agents, and can't be deleted",
              model.agentTokens.first?.automatic == true && model.agentTokens.first?.name == "Automatic")
        check("S-064 the Keychain keeps a fingerprint, not the token",
              PasswordStore.secret(token.keychainAccount) == AgentTokenValue.fingerprint(value) && !value.isEmpty)

        model.setRevoked(token, true)
        let revoked = await call(value, "list_connections")
        model.setRevoked(token, false)
        let restored = await call(value, "list_connections")
        check("S-064 a revoked token is refused and stays listed; Restore makes it work again",
              revoked.status == 403 && revoked.text.contains("revoked") && restored.ok
                  && model.agentTokens.contains { $0.uid == token.uid }, "\(revoked.status) \(restored.status)")

        // A token for one connection only.
        let (limited, limitedValue) = model.createAgentToken(
            name: "Only MCP Local", access: AgentAccess(permission: .readOnly, allConnections: false, connections: [uid]))
        let listed = await call(limitedValue, "list_connections")
        let ids = JSONValue.parse(Data(listed.text.utf8))?["connections"]?.array?.compactMap { $0["id"]?.string } ?? []
        let front = await call(limitedValue, "list_databases")
        let chosen = await call(limitedValue, "list_databases", ["connection": .string(id)])
        check("S-064 a token limited to some connections sees only those",
              ids == [id] && !front.ok && front.text.contains("can’t use") && chosen.ok, ids.joined(separator: ",") + " | " + front.text)

        // Custom: read only on this connection, so no writes.
        let (custom, customValue) = model.createAgentToken(name: "Custom", access: AgentAccess(permission: .custom, custom: [uid: .read]))
        let customWrite = await call(customValue, "write_query", ["connection": .string(id), "sql": "DO 1"])
        check("S-064 a Custom token that is read only on a connection can't write there",
              !customWrite.ok && customWrite.text.contains("read only"), customWrite.text)

        // Approve Agent Change.
        model.updateAgentToken(token, name: token.name, access: .readWrite)
        host.askOverride = true
        _ = try? await session.client?.run("CREATE TABLE IF NOT EXISTS quarry_demo.mcp_scratch (id INT)")
        let insert: JSONValue = ["connection": .string(id), "database": "quarry_demo", "sql": "INSERT INTO mcp_scratch VALUES (64)"]
        let allowed = Task { await call(value, "write_query", insert) }
        await until { AgentApprovals.current != nil }
        let asked = AgentApprovals.current
        let shown = Tabs.allSessions().first { $0.agentApproval != nil }
        await until { shown?.window?.attachedSheet != nil }
        check("S-064 with Ask before changes, Approve Agent Change shows the statement on a visible window",
              asked?.statement.contains("VALUES (64)") == true && asked?.database == "quarry_demo" && asked?.client.isEmpty == false
                  // NSApp.activate() is a request: with another app full screen the system may refuse it, so it isn't checked.
                  && shown?.window?.attachedSheet != nil && shown?.window?.isVisible == true,
              "\(asked?.statement ?? "no question") db \(asked?.database ?? "nil") client \(asked?.client ?? "") "
                  + "shown \(shown != nil) sheet \(shown?.window?.attachedSheet != nil) active \(NSApp.isActive)")
        asked?.answer(true)
        let allowedResult = await allowed.value
        let inserted = await firstValue(in: session, "SELECT COUNT(*) FROM quarry_demo.mcp_scratch WHERE id = 64")
        check("S-064 Allow runs the change", allowedResult.ok && inserted == "1", allowedResult.text)

        let denied = Task { await call(value, "write_query", insert) }
        await until { AgentApprovals.current != nil }
        AgentApprovals.current?.answer(false)
        let deniedResult = await denied.value
        AgentApprovals.timeout = 1
        let unanswered = await call(value, "write_query", insert)
        AgentApprovals.timeout = 120
        let count = await firstValue(in: session, "SELECT COUNT(*) FROM quarry_demo.mcp_scratch WHERE id = 64")
        check("S-064 Deny, and no answer in time, leave the data alone and tell the agent",
              !deniedResult.ok && deniedResult.text.contains("denied") && !unanswered.ok && unanswered.text.contains("No one answered")
                  && count == "1" && Tabs.allSessions().allSatisfy { $0.agentApproval == nil },
              deniedResult.text + " | " + unanswered.text)
        host.askOverride = false

        model.deleteAgentToken(limited)
        let deleted = await call(limitedValue, "list_connections")
        check("S-064 Delete removes a token, and its agents can't use it again",
              deleted.status == 401 && !model.agentTokens.contains { $0.uid == limited.uid }
                  && PasswordStore.secret(limited.keychainAccount) == nil, "\(deleted.status)")
        model.deleteAgentToken(custom)
        model.updateAgentToken(token, name: token.name, access: .readOnly)
    }

    /// `Quarry mcp`, as an agent's stdio client runs it: two requests in, two answers out.
    private static func bridge() async {
        guard let binary = Bundle.main.executableURL else { return }
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"bridge-test"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_databases"}}"#,
        ]
        let output: String = await Task.detached {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["mcp"]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            for line in lines {
                input.fileHandleForWriting.write(Data((line + "\n").utf8))
                // Leave time for the answer before the next request, as a client would.
                usleep(300_000)
            }
            try? input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
        let answers = output.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
        let databases = answers.first { $0["id"] == 2 }?["result"]?["content"]?.array?.first?["text"]?.string ?? ""
        check("S-063 the stdio bridge (Quarry mcp) passes requests to the running app and answers back",
              answers.count == 2 && answers.first { $0["id"] == 1 }?["result"]?["serverInfo"]?["name"] == "quarry"
                  && databases.contains("quarry_demo"), String(output.prefix(300)))
    }

    /// One HTTP request to the MCP endpoint.
    static func post(_ port: Int, _ body: JSONValue, token: String?, session: String? = nil, origin: String? = nil,
                             method: String = "POST") async -> (status: Int, json: JSONValue?, session: String?) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = method
        request.timeoutInterval = 30
        if method == "POST" { request.httpBody = body.data }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else {
            return (0, nil, nil)
        }
        return (http.statusCode, JSONValue.parse(data), http.value(forHTTPHeaderField: "Mcp-Session-Id"))
    }
}
