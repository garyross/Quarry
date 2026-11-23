import Foundation
import Testing
@testable import QuarryKit

struct AgentSQLTests {
    @Test(arguments: ["SELECT 1", "  select * from t where a = 'DROP TABLE x'", "SHOW TABLES", "DESCRIBE t", "desc t",
                      "EXPLAIN SELECT 1", "WITH x AS (SELECT 1) SELECT * FROM x", "(SELECT 1) UNION (SELECT 2)",
                      "SELECT `into`, `outfile` FROM t", "SELECT 'INTO OUTFILE' AS a", "SELECT 1;", "-- note\nSELECT 1",
                      "SELECT REPLACE(name, 'a', 'b') FROM t", "SELECT a FROM t WHERE b = ?"])
    func readsPass(sql: String) {
        #expect(AgentSQL.readProblem(sql, engine: .mysql) == nil)
    }

    @Test(arguments: ["DELETE FROM t", "UPDATE t SET a = 1", "DROP TABLE t", "CREATE TABLE x (a int)", "SET @a = 1",
                      "CALL p()", "USE quarry_demo", "START TRANSACTION", "LOCK TABLES t READ", "INSERT INTO t VALUES (1)",
                      "SELECT 1; DROP TABLE t", "SELECT * FROM t INTO OUTFILE '/tmp/x'", "SELECT * INTO DUMPFILE '/tmp/x' FROM t",
                      "SELECT LOAD_FILE('/etc/passwd')", "SELECT * FROM t FOR UPDATE", "SELECT * FROM t LOCK IN SHARE MODE",
                      "SELECT /*! 1; DROP TABLE t */", "SELECT /*M!100000 SLEEP(1) */ 1", "EXPLAIN ANALYZE SELECT 1",
                      "", "  ", "SELECT 'unclosed"])
    func writesAndTricksFail(sql: String) {
        #expect(AgentSQL.readProblem(sql, engine: .mysql) != nil)
    }

    @Test func statementsAreOneAtATime() {
        #expect(AgentSQL.statementProblem("UPDATE t SET a = 1", engine: .mysql) == nil)
        #expect(AgentSQL.statementProblem("UPDATE t SET a = 1; DELETE FROM t", engine: .mysql)?.contains("one statement") == true)
        #expect(AgentSQL.firstKeyword("  /* c */ select 1") == "SELECT")
    }

    @Test func placeholdersBecomeQuotedValues() throws {
        let sql = try AgentSQL.bind("SELECT * FROM t WHERE a = ? AND b = ? AND c = ? AND d = ? AND e = '?' -- ?\n",
                                    ["it's", 3, true, nil], engine: .mysql)
        #expect(sql == "SELECT * FROM t WHERE a = 'it\\'s' AND b = 3 AND c = TRUE AND d = NULL AND e = '?' -- ?\n")
        #expect(throws: AgentSQL.BindError.self) { try AgentSQL.bind("SELECT ?", [], engine: .mysql) }
        #expect(throws: AgentSQL.BindError.self) { try AgentSQL.bind("SELECT ?", [["a"]], engine: .mysql) }
        #expect(try AgentSQL.bind("SELECT 'é' = ?", ["ü"], engine: .mysql) == "SELECT 'é' = 'ü'")
    }

    /// SQLite text has no backslash escapes: a quote is doubled, a backslash stays one
    /// character, and a backslash before a quote in the SQL doesn't hide a placeholder.
    @Test func placeholdersQuoteForSQLite() throws {
        let sql = try AgentSQL.bind("SELECT * FROM t WHERE a = ? AND b = ? AND c = '\\' AND d = ?",
                                    ["it's", "a\\b\nc", 2], engine: .sqlite)
        #expect(sql == "SELECT * FROM t WHERE a = 'it''s' AND b = 'a\\b\nc' AND c = '\\' AND d = 2")
        #expect(AgentSQL.readProblem(sql, engine: .sqlite) == nil)
    }
}

struct MCPHTTPPolicyTests {
    let good = ["host": "127.0.0.1:53306", "authorization": "Bearer secret"]
    let tokens = [AgentTokenValue.fingerprint("secret"): true, AgentTokenValue.fingerprint("old"): false]

    @Test func onlyThisMacWithTheToken() {
        #expect(MCPHTTPPolicy.refusal(method: "POST", path: "/mcp", headers: good, tokens: tokens, port: 53306) == nil)
        #expect(MCPHTTPPolicy.refusal(method: "POST", path: "/other", headers: good, tokens: tokens, port: 53306)?.status == 404)
        var rebound = good
        rebound["host"] = "evil.example:53306"
        #expect(MCPHTTPPolicy.refusal(method: "POST", path: "/mcp", headers: rebound, tokens: tokens, port: 53306)?.status == 403)
        var page = good
        page["origin"] = "https://evil.example"
        #expect(MCPHTTPPolicy.refusal(method: "POST", path: "/mcp", headers: page, tokens: tokens, port: 53306)?.status == 403)
        page["origin"] = "http://localhost:3000"
        #expect(MCPHTTPPolicy.refusal(method: "POST", path: "/mcp", headers: page, tokens: tokens, port: 53306) == nil)
        var wrong = good
        wrong["authorization"] = "Bearer nope"
        #expect(MCPHTTPPolicy.refusal(method: "POST", path: "/mcp", headers: wrong, tokens: tokens, port: 53306)?.status == 401)
        #expect(MCPHTTPPolicy.refusal(method: "POST", path: "/mcp", headers: good, tokens: [:], port: 53306)?.status == 401)
        #expect(MCPHTTPPolicy.refusal(method: "GET", path: "/mcp", headers: good, tokens: tokens, port: 53306)?.status == 405)
        var revoked = good
        revoked["authorization"] = "Bearer old"
        #expect(MCPHTTPPolicy.refusal(method: "POST", path: "/mcp", headers: revoked, tokens: tokens, port: 53306)?.status == 403)
        #expect(MCPHTTPPolicy.fingerprint(good) == AgentTokenValue.fingerprint("secret"))
    }
}

struct AgentAccessTests {
    let a = UUID(), b = UUID(), group = UUID()

    @Test func readOnlyAndReadWriteReachAllOrChosen() {
        #expect(AgentAccess.readOnly.level(connection: a, group: nil) == .read)
        #expect(AgentAccess.readOnly.level(connection: nil, group: nil) == .read)
        #expect(AgentAccess.readWrite.level(connection: a, group: group) == .write)
        let chosen = AgentAccess(permission: .readWrite, allConnections: false, connections: [a], groups: [group])
        #expect(chosen.level(connection: a, group: nil) == .write)
        #expect(chosen.level(connection: b, group: group) == .write)
        #expect(chosen.level(connection: b, group: nil) == .none)
        #expect(chosen.level(connection: nil, group: nil) == .none)
        #expect(chosen.summary == "Read & Write · 1 connection, 1 group")
    }

    @Test func customIsPerConnection() {
        let custom = AgentAccess(permission: .custom, custom: [a: .write, b: .read])
        #expect(custom.level(connection: a, group: nil) == .write)
        #expect(custom.level(connection: b, group: nil) == .read)
        #expect(custom.level(connection: UUID(), group: group) == .none)
        #expect(custom.level(connection: nil, group: nil) == .none)
        #expect(custom.summary == "Custom · 2 connections")
        let data = try? JSONEncoder().encode(custom)
        #expect(data.flatMap { try? JSONDecoder().decode(AgentAccess.self, from: $0) } == custom)
    }

    @Test func tokenValuesAreRandomAndOnlyFingerprinted() {
        let one = AgentTokenValue.make(), two = AgentTokenValue.make()
        #expect(one != two && one.hasPrefix("qmcp_") && one.count > 40)
        #expect(AgentTokenValue.fingerprint(one).count == 64 && AgentTokenValue.fingerprint(one) != AgentTokenValue.fingerprint(two))
    }
}

@MainActor
final class EchoHandler: MCPHandler {
    var tools: [MCPTool] {
        [MCPTool(name: "echo", title: "Echo", description: "Says it back.", parameters: ["text": ["type": "string"]], required: ["text"]),
         MCPTool(name: "fail", title: "Fail", description: "Always fails.", readOnly: false, destructive: true)]
    }

    func callTool(_ name: String, arguments: [String: JSONValue], client: MCPClient) async throws -> JSONValue {
        if name == "fail" { throw MCPToolError("It failed, as asked.") }
        return ["text": arguments["text"] ?? .null]
    }

    func resources() async -> [MCPResource] { [MCPResource(uri: "quarry://a/b/c", name: "c", description: "Table c")] }
    var resourceTemplates: [MCPResource] { [MCPResource(uri: "quarry://{connection}/{database}/{table}", name: "Table", description: "")] }
    func readResource(_ uri: String) async throws -> String { "{\"uri\":\"\(uri)\"}" }
    var prompts: [MCPPrompt] { [MCPPrompt(name: "p", title: "P", description: "A prompt.")] }
    func prompt(_ name: String, arguments: [String: String]) throws -> String { "Prompt \(name)" }
    func complete(argument: String, value: String, context: [String: String]) async -> [String] {
        ["alpha", "beta"].filter { $0.hasPrefix(value) }
    }
}

@MainActor
struct MCPRouterTests {
    let handler = EchoHandler()

    func send(_ router: MCPRouter, _ json: String, client: MCPClient) async -> JSONValue? {
        guard let reply = await router.handle(Data(json.utf8), client: client) else { return nil }
        return JSONValue.parse(reply)
    }

    @Test func protocolRoundTrip() async {
        let router = MCPRouter(serverVersion: "1.0", instructions: "Hi", handler: handler)
        let client = MCPClient(transport: "test")
        let hello = await send(router, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"claude-code","version":"2.1"}}}"#, client: client)
        #expect(hello?["result"]?["protocolVersion"] == "2025-03-26")
        #expect(hello?["result"]?["serverInfo"]?["name"] == "quarry")
        #expect(client.displayName == "claude-code 2.1")
        #expect(await send(router, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, client: client) == nil)
        #expect(MCPRouter.isNotification(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))

        let list = await send(router, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, client: client)
        let tools = list?["result"]?["tools"]?.array ?? []
        #expect(tools.count == 2)
        #expect(tools.first?["annotations"]?["readOnlyHint"] == true)
        #expect(tools.last?["annotations"]?["destructiveHint"] == true)

        let echo = await send(router, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#, client: client)
        #expect(echo?["result"]?["isError"] == false)
        #expect(echo?["result"]?["content"]?.array?.first?["text"] == #"{"text":"hi"}"#)

        let fail = await send(router, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"fail"}}"#, client: client)
        #expect(fail?["result"]?["isError"] == true)
        #expect(fail?["result"]?["content"]?.array?.first?["text"] == "It failed, as asked.")

        let unknown = await send(router, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope"}}"#, client: client)
        #expect(unknown?["result"]?["isError"] == true)

        let complete = await send(router, #"{"jsonrpc":"2.0","id":6,"method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"p"},"argument":{"name":"table","value":"b"}}}"#, client: client)
        #expect(complete?["result"]?["completion"]?["values"] == ["beta"])

        let read = await send(router, #"{"jsonrpc":"2.0","id":7,"method":"resources/read","params":{"uri":"quarry://a/b/c"}}"#, client: client)
        #expect(read?["result"]?["contents"]?.array?.first?["text"] == #"{"uri":"quarry://a/b/c"}"#)

        let missing = await send(router, #"{"jsonrpc":"2.0","id":8,"method":"nope/nope"}"#, client: client)
        #expect(missing?["error"]?["code"] == -32601)
        let garbage = await send(router, "not json", client: client)
        #expect(garbage?["error"]?["code"] == -32700)
        #expect(client.requests == 8)
    }

    @Test func unknownVersionGetsTheLatest() async {
        let router = MCPRouter(serverVersion: "1.0", instructions: "", handler: handler)
        let hello = await send(router, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#,
                               client: MCPClient(transport: "test"))
        #expect(hello?["result"]?["protocolVersion"] == .string(MCPRouter.latestVersion))
    }
}

struct AgentRowsTests {
    @Test func valuesAsJSON() {
        let columns = [ResultColumn(name: "id", isNumeric: true), ResultColumn(name: "price", typeName: "decimal", isNumeric: true),
                       ResultColumn(name: "name"), ResultColumn(name: "photo", isBinary: true)]
        let rows = AgentRows(columns: columns, rows: [[.text("7"), .text("9.50"), .null, .binary(Data([1, 255]))]],
                             total: 3, affectedRows: nil, duration: .milliseconds(12))
        let json = rows.json(offset: 1)
        #expect(json["rows"] == [[7, "9.50", nil, "0x01FF"]])
        #expect(json["nextOffset"] == 2)
        #expect(json["totalRows"] == 3)
        #expect(json["seconds"] == 0.012)
        let long = AgentRows.value(.text(String(repeating: "a", count: 20)), ResultColumn(name: "t"), limit: 5)
        #expect(long.string?.hasPrefix("aaaaa… (20 characters") == true)
    }
}
