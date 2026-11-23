import Foundation

// The Model Context Protocol (S-063): JSON-RPC 2.0 messages from agents such
// as Claude Code, over stdio (through `Quarry mcp`) or Streamable HTTP. The
// router answers the protocol's own methods and hands tools, resources,
// prompts and completions to an `MCPHandler`, the app.

/// One tool an agent can call.
public struct MCPTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    /// Each parameter by name: its JSON schema.
    public var parameters: [String: JSONValue]
    public var required: [String]
    /// Only reads: clients may run it without asking.
    public var readOnly: Bool
    /// Changes or removes something that can't be undone.
    public var destructive: Bool

    public init(name: String, title: String, description: String, parameters: [String: JSONValue] = [:],
                required: [String] = [], readOnly: Bool = true, destructive: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.parameters = parameters
        self.required = required
        self.readOnly = readOnly
        self.destructive = destructive
    }

    public var json: JSONValue {
        ["name": .string(name), "title": .string(title), "description": .string(description),
         "inputSchema": ["type": "object", "properties": .object(parameters), "required": .array(required.map(JSONValue.string))],
         "annotations": ["title": .string(title), "readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive),
                         "idempotentHint": .bool(readOnly), "openWorldHint": false]]
    }
}

/// A prompt template an agent's person can pick.
public struct MCPPrompt: Sendable {
    public struct Argument: Sendable {
        public var name: String
        public var description: String
        public var required: Bool
        public init(name: String, description: String, required: Bool = false) {
            self.name = name
            self.description = description
            self.required = required
        }
    }

    public var name: String
    public var title: String
    public var description: String
    public var arguments: [Argument]

    public init(name: String, title: String, description: String, arguments: [Argument] = []) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
    }

    public var json: JSONValue {
        ["name": .string(name), "title": .string(title), "description": .string(description),
         "arguments": .array(arguments.map { ["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)] })]
    }
}

/// A resource, or a template for many (`quarry://{connection}/{database}/{table}`).
public struct MCPResource: Sendable {
    public var uri: String
    public var name: String
    public var description: String
    public var mimeType: String

    public init(uri: String, name: String, description: String, mimeType: String = "application/json") {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
    }
}

/// A failure an agent should read: the tool ran and could not do it.
public struct MCPToolError: Error, Sendable, LocalizedError {
    public var message: String
    /// The person or the token said no (S-065 shows it as Denied, not Error).
    public var denied: Bool
    public init(_ message: String, denied: Bool = false) {
        self.message = message
        self.denied = denied
    }
    public var errorDescription: String? { message }
}

/// The app's side: the tools and what they do.
@MainActor
public protocol MCPHandler: AnyObject {
    var tools: [MCPTool] { get }
    func callTool(_ name: String, arguments: [String: JSONValue], client: MCPClient) async throws -> JSONValue
    func resources() async -> [MCPResource]
    var resourceTemplates: [MCPResource] { get }
    /// The resource's text (JSON).
    func readResource(_ uri: String) async throws -> String
    var prompts: [MCPPrompt] { get }
    /// The prompt's text, for one user message.
    func prompt(_ name: String, arguments: [String: String]) throws -> String
    /// Values that start with `value` for `argument`, given the arguments already filled.
    func complete(argument: String, value: String, context: [String: String]) async -> [String]
}

/// One agent session: a stdio bridge connection or an HTTP session.
@MainActor
public final class MCPClient: Identifiable {
    public let id = UUID()
    /// "claude-code 2.1.0" from initialize's clientInfo.
    public private(set) var name = ""
    public private(set) var version = ""
    public private(set) var protocolVersion = MCPRouter.latestVersion
    public let transport: String
    public let started = Date()
    public private(set) var lastActivity = Date()
    public private(set) var requests = 0
    /// The token it came with (S-064): an HTTP token, or the Automatic token for stdio.
    public let tokenID: UUID?

    public init(transport: String, tokenID: UUID? = nil) {
        self.transport = transport
        self.tokenID = tokenID
    }

    func noteRequest() {
        requests += 1
        lastActivity = Date()
    }

    func introduce(name: String, version: String, protocolVersion: String) {
        self.name = name
        self.version = version
        self.protocolVersion = protocolVersion
    }

    /// "claude-code 2.1.0", or "Unknown client" before initialize.
    public var displayName: String {
        name.isEmpty ? "Unknown client" : [name, version].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

@MainActor
public final class MCPRouter {
    public static let latestVersion = "2025-06-18"
    public static let supportedVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    public let serverVersion: String
    public let instructions: String
    public weak var handler: (any MCPHandler)?

    public init(serverVersion: String, instructions: String, handler: (any MCPHandler)?) {
        self.serverVersion = serverVersion
        self.instructions = instructions
        self.handler = handler
    }

    /// The reply to one message (or a batch), or nil for notifications.
    public func handle(_ data: Data, client: MCPClient) async -> Data? {
        guard let message = JSONValue.parse(data) else {
            return Self.error(id: .null, code: -32700, "The message is not JSON.").data
        }
        if let batch = message.array {
            var replies: [JSONValue] = []
            for item in batch { if let reply = await reply(to: item, client: client) { replies.append(reply) } }
            return replies.isEmpty ? nil : JSONValue.array(replies).data
        }
        return await reply(to: message, client: client)?.data
    }

    /// True when `data` is only notifications or responses, which get no reply (HTTP 202).
    public static func isNotification(_ data: Data) -> Bool {
        guard let message = JSONValue.parse(data) else { return false }
        let items = message.array ?? [message]
        return !items.isEmpty && items.allSatisfy { $0["id"] == nil || $0["method"] == nil }
    }

    func reply(to message: JSONValue, client: MCPClient) async -> JSONValue? {
        guard let method = message["method"]?.string else { return nil }
        // Notifications (no id) get no answer.
        guard let id = message["id"] else { return nil }
        client.noteRequest()
        let params = message["params"] ?? [:]
        do {
            let result = try await answer(method, params, client: client)
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let failure as Failure {
            return Self.error(id: id, code: failure.code, failure.message)
        } catch {
            return Self.error(id: id, code: -32603, error.localizedDescription)
        }
    }

    struct Failure: Error {
        var code: Int
        var message: String
        static func params(_ message: String) -> Failure { Failure(code: -32602, message: message) }
    }

    public static func error(id: JSONValue, code: Int, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }

    private func answer(_ method: String, _ params: JSONValue, client: MCPClient) async throws -> JSONValue {
        guard let handler else { throw Failure(code: -32603, message: "Quarry is closing.") }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? Self.latestVersion
            let version = Self.supportedVersions.contains(asked) ? asked : Self.latestVersion
            client.introduce(name: params["clientInfo"]?["name"]?.string ?? "",
                             version: params["clientInfo"]?["version"]?.string ?? "", protocolVersion: version)
            return ["protocolVersion": .string(version),
                    "capabilities": ["tools": ["listChanged": false], "resources": ["listChanged": false, "subscribe": false],
                                     "prompts": ["listChanged": false], "completions": [:], "logging": [:]],
                    "serverInfo": ["name": "quarry", "title": "Quarry", "version": .string(serverVersion)],
                    "instructions": .string(instructions)]
        case "ping", "logging/setLevel":
            return [:]
        case "tools/list":
            return ["tools": .array(handler.tools.map(\.json))]
        case "tools/call":
            guard let name = params["name"]?.string else { throw Failure.params("tools/call needs a name.") }
            let arguments = params["arguments"]?.object ?? [:]
            guard handler.tools.contains(where: { $0.name == name }) else {
                return Self.toolResult("No tool named \(name). Ask for tools/list.", isError: true)
            }
            do {
                let result = try await handler.callTool(name, arguments: arguments, client: client)
                return Self.toolResult(result.text, isError: false)
            } catch {
                let message = (error as? MCPToolError)?.message ?? (error as? LocalizedError)?.errorDescription ?? "\(error)"
                return Self.toolResult(message, isError: true)
            }
        case "resources/list":
            return ["resources": .array(await handler.resources().map(Self.resourceJSON))]
        case "resources/templates/list":
            return ["resourceTemplates": .array(handler.resourceTemplates.map { resource in
                ["uriTemplate": .string(resource.uri), "name": .string(resource.name),
                 "description": .string(resource.description), "mimeType": .string(resource.mimeType)]
            })]
        case "resources/read":
            guard let uri = params["uri"]?.string else { throw Failure.params("resources/read needs a uri.") }
            do {
                let text = try await handler.readResource(uri)
                return ["contents": [["uri": .string(uri), "mimeType": "application/json", "text": .string(text)]]]
            } catch {
                throw Failure(code: -32002, message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        case "prompts/list":
            return ["prompts": .array(handler.prompts.map(\.json))]
        case "prompts/get":
            guard let name = params["name"]?.string, let prompt = handler.prompts.first(where: { $0.name == name }) else {
                throw Failure.params("No prompt named \(params["name"]?.string ?? ""). Ask for prompts/list.")
            }
            let arguments = (params["arguments"]?.object ?? [:]).compactMapValues { $0.string }
            let text = try handler.prompt(name, arguments: arguments)
            return ["description": .string(prompt.description),
                    "messages": [["role": "user", "content": ["type": "text", "text": .string(text)]]]]
        case "completion/complete":
            let argument = params["argument"]?["name"]?.string ?? ""
            let value = params["argument"]?["value"]?.string ?? ""
            let context = (params["context"]?["arguments"]?.object ?? [:]).compactMapValues { $0.string }
            let values = Array(await handler.complete(argument: argument, value: value, context: context).prefix(100))
            return ["completion": ["values": .array(values.map(JSONValue.string)), "total": .int(values.count), "hasMore": false]]
        default:
            throw Failure(code: -32601, message: "Quarry doesn't know the method \(method).")
        }
    }

    static func toolResult(_ text: String, isError: Bool) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    static func resourceJSON(_ resource: MCPResource) -> JSONValue {
        ["uri": .string(resource.uri), "name": .string(resource.name), "description": .string(resource.description),
         "mimeType": .string(resource.mimeType)]
    }
}
