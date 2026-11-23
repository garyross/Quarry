import AppKit
import QuarryKit
import SwiftData

/// Self-test: MCP Activity (S-065), after the S-063 and S-064 checks have made requests.
extension SelfTest {
    static func activity(model: AppModel, port: Int, value: String) async {
        let host = MCPHost.shared
        let mine = model.agentActivity.filter { $0.token == "Self-test" }
        let read = mine.first { $0.tool == "read_query" && $0.status == .ok }
        let denied = mine.first { $0.tool == "write_query" && $0.status == .denied && $0.message.contains("read only") }
        let failed = mine.first { $0.status == .error }
        check("S-065 every request is logged with time, client, token, connection, tool, statement, status and duration",
              read?.client == "selftest 1" && read?.statement.uppercased().contains("SELECT") == true && read?.duration ?? -1 >= 0
                  && !(read?.connection.isEmpty ?? true) && denied?.message.contains("read only") == true && failed != nil
                  && model.agentActivity.contains { $0.tool == "resources/read" && $0.database == "quarry_demo" },
              "\(mine.count) requests; read \(read?.statement ?? "none") on \(read?.connection ?? "") by \(read?.client ?? "") denied "
                  + "\(denied?.message.prefix(60) ?? "none") error \(failed != nil) resources "
                  + model.agentActivity.filter { $0.tool == "resources/read" }.map { "\($0.database)/\($0.status.rawValue)/\($0.token)" }.joined(separator: ","))

        let stored = (try? model.context.fetchCount(FetchDescriptor<AgentRequest>())) ?? -1
        check("S-065 the log is kept in the store", stored == model.agentActivity.count && stored > 0, "\(stored) of \(model.agentActivity.count)")

        let byToken = ActivityFilter(token: "Self-test").apply(model.agentActivity)
        let byText = ActivityFilter(text: "write_query denied").apply(model.agentActivity)
        let csv = AgentActivity.csv(byToken)
        check("S-065 the filter narrows by token and words, and Export CSV writes what is shown",
              byToken.count == mine.count && !byText.isEmpty && byText.allSatisfy { $0.status == .denied }
                  && csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count >= byToken.count + 1
                  && csv.hasPrefix("Time,Client,Token"), "\(byToken.count) by token, \(byText.count) by text")

        // At most 30 days: an old request goes at the next reload (launch, or hourly).
        func old(_ days: Double) -> ActivityRecord {
            ActivityRecord(date: .now.addingTimeInterval(-days * 86_400), client: "old", token: "Old", connection: "Local",
                           database: "", tool: "list_tables", statement: "", status: .ok, duration: 0)
        }
        model.logAgentRequest(old(40))
        model.logAgentRequest(old(2))
        model.reloadAgentActivity()
        check("S-065 requests older than 30 days are dropped",
              !model.agentActivity.contains { $0.token == "Old" && $0.date < AgentActivity.retentionCutoff() }
                  && model.agentActivity.contains { $0.token == "Old" })
        model.clearAgentActivity(before: .now.addingTimeInterval(-86_400))
        let afterDay = model.agentActivity
        check("S-065 Clear Activity > Older Than 24 Hours keeps the recent ones",
              !afterDay.contains { $0.token == "Old" } && afterDay.contains { $0.token == "Self-test" })

        // Disconnect over HTTP: the running query stops and the session ends.
        let hello: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "activity-test", "version": "1"]]]
        let opened = await post(port, hello, token: value)
        let sid = opened.session
        let clock = ContinuousClock()
        let start = clock.now
        let sleeping = Task {
            await post(port, ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                              "params": ["name": "read_query", "arguments": ["sql": "SELECT SLEEP(30)"]]], token: value, session: sid)
        }
        try? await Task.sleep(for: .seconds(1.5))
        if let client = host.clients.first(where: { $0.name == "activity-test" }) {
            MCPActivityState.shared.page = .clients
            await host.disconnect(client: client)
        }
        let stopped = await sleeping.value
        let elapsed = clock.now - start
        let again = await post(port, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "list_connections"]],
                               token: value, session: sid)
        check("S-065 Disconnect ends an HTTP agent's session and stops its running query",
              elapsed < .seconds(10) && stopped.json?["result"]?["isError"] == true && again.status == 404
                  && !host.clients.contains { $0.name == "activity-test" },
              "\(elapsed) \(again.status) \(stopped.json?.text.prefix(200) ?? "")")

        await disconnectBridge(host: host)
        MCPActivityState.shared.page = .requests

        model.clearAgentActivity(before: nil)
        check("S-065 Clear Activity > All forgets every request",
              model.agentActivity.isEmpty && (try? model.context.fetchCount(FetchDescriptor<AgentRequest>())) == 0)
    }

    /// Disconnect on a stdio agent closes its bridge, and `Quarry mcp` exits.
    private static func disconnectBridge(host: MCPHost) async {
        guard let binary = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["mcp"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return check("S-065 Disconnect closes a stdio agent's bridge", false, "no bridge") }
        let line = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"bridge-disconnect"}}}"#
        input.fileHandleForWriting.write(Data((line + "\n").utf8))
        for _ in 0..<50 where !host.clients.contains(where: { $0.name == "bridge-disconnect" }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let client = host.clients.first { $0.name == "bridge-disconnect" }
        if let client { await host.disconnect(client: client) }
        for _ in 0..<50 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        let exited = !process.isRunning
        if !exited { process.terminate() }
        try? input.fileHandleForWriting.close()
        check("S-065 Disconnect closes a stdio agent's bridge, and the client leaves the list",
              client?.transport == "stdio" && exited && !host.clients.contains { $0.name == "bridge-disconnect" },
              "found \(client != nil) exited \(exited)")
    }
}
