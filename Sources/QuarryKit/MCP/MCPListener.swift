import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

/// One MCP message as it arrived, and where from (S-063).
public struct MCPIncoming: Sendable {
    public enum Transport: Sendable, Equatable {
        /// A `Quarry mcp` bridge on the private Unix socket; the id names its connection.
        case socket(UUID)
        /// Streamable HTTP; the Mcp-Session-Id header, if the client sent one.
        case http(session: String?)
    }

    public var body: Data
    public var transport: Transport
    /// HTTP: the fingerprint of the token the request came with (S-064); nil on the socket.
    public var token: String?
}

/// The answer: a JSON body, or none for notifications. `session` becomes the
/// Mcp-Session-Id header (initialize over HTTP).
public struct MCPOutgoing: Sendable {
    public var body: Data?
    public var session: String?
    /// HTTP: a status other than 200/202, such as 404 for a session Quarry ended (S-065).
    public var status: Int?
    public init(body: Data?, session: String? = nil, status: Int? = nil) {
        self.body = body
        self.session = session
        self.status = status
    }
}

/// Who may talk to the HTTP endpoint: only this Mac, at /mcp, with the token.
public enum MCPHTTPPolicy {
    public struct Refusal: Equatable, Sendable {
        public var status: Int
        public var message: String
    }

    /// Why a request is refused, or nil to answer it. `headers` names are lowercase.
    /// `tokens` maps each token's fingerprint to whether it works (false: revoked).
    public static func refusal(method: String, path: String, headers: [String: String], tokens: [String: Bool], port: Int) -> Refusal? {
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        guard route == "/mcp" || route == "/mcp/" else { return Refusal(status: 404, message: "Quarry's MCP endpoint is /mcp.") }
        // DNS rebinding: a web page can reach 127.0.0.1 under its own name; the Host header gives it away.
        let host = headers["host"]?.lowercased() ?? ""
        let hosts = ["127.0.0.1", "localhost", "[::1]"].flatMap { [$0, "\($0):\(port)"] }
        guard hosts.contains(host) else { return Refusal(status: 403, message: "Only this Mac can use Quarry's MCP server.") }
        if let origin = headers["origin"], !isLoopback(origin: origin) {
            return Refusal(status: 403, message: "Web pages can't use Quarry's MCP server.")
        }
        guard let fingerprint = fingerprint(headers), let works = tokens[fingerprint] else {
            return Refusal(status: 401, message: "Send a token from Quarry > Settings > MCP > Tokens as Authorization: Bearer <token>.")
        }
        guard works else { return Refusal(status: 403, message: "This token was revoked in Quarry > Settings > MCP.") }
        guard ["POST", "DELETE"].contains(method) else {
            return Refusal(status: 405, message: "Quarry's MCP endpoint takes POST (and DELETE to end a session).")
        }
        return nil
    }

    static func isLoopback(origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    /// The SHA-256 of the bearer token, or nil when there is none. Comparing
    /// fingerprints, not values, leaves nothing to time.
    public static func fingerprint(_ headers: [String: String]) -> String? {
        guard let auth = headers["authorization"], auth.lowercased().hasPrefix("bearer ") else { return nil }
        let value = String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : AgentTokenValue.fingerprint(value)
    }
}

/// The MCP server's two doors: Streamable HTTP on 127.0.0.1, and a Unix
/// socket only this Mac user can open, where `Quarry mcp` bridges stdio.
/// Messages go to `handle`; socket connections report open and close.
public final class MCPListener: Sendable {
    public typealias Handle = @Sendable (MCPIncoming) async -> MCPOutgoing
    public typealias Ended = @Sendable (MCPIncoming.Transport) async -> Void

    private let handle: Handle
    private let ended: Ended
    private let tokenBox: NIOLockedValueBox<[String: Bool]>
    private let channels = NIOLockedValueBox<[any Channel]>([])
    /// Each bridge's connection on the socket, so one can be closed (S-065's Disconnect).
    private let bridges = NIOLockedValueBox<[UUID: any Channel]>([:])

    /// `tokens`: fingerprint to whether the token works (false: revoked).
    public init(tokens: [String: Bool], handle: @escaping Handle, ended: @escaping Ended) {
        self.handle = handle
        self.ended = ended
        self.tokenBox = NIOLockedValueBox(tokens)
    }

    /// The tokens HTTP requests may carry, by fingerprint; changed as the owner makes, revokes and deletes them.
    public var tokens: [String: Bool] {
        get { tokenBox.withLockedValue { $0 } }
        set { tokenBox.withLockedValue { $0 = newValue } }
    }

    /// Listens on 127.0.0.1:`port` (0 picks a free one). Returns the port in use.
    public func listenHTTP(port: Int) async throws -> Int {
        let handle = self.handle
        let ended = self.ended
        let tokenBox = self.tokenBox
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(
                        HTTPHandler(handle: handle, ended: ended, tokens: { tokenBox.withLockedValue { $0 } }))
                }
            }
            .bind(host: "127.0.0.1", port: port).get()
        channels.withLockedValue { $0.append(channel) }
        return channel.localAddress?.port ?? port
    }

    /// Listens on a Unix socket at `path`, readable and writable only by this user.
    public func listenSocket(path: String) async throws {
        let handle = self.handle
        let ended = self.ended
        let bridges = self.bridges
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = LineHandler(handle: handle, ended: ended)
                    bridges.withLockedValue { $0[handler.id] = channel }
                    channel.closeFuture.whenComplete { _ in _ = bridges.withLockedValue { $0.removeValue(forKey: handler.id) } }
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
            .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true).get()
        chmod(path, 0o600)
        channels.withLockedValue { $0.append(channel) }
    }

    /// Closes one bridge's connection; its `Quarry mcp` process then exits.
    public func close(socket id: UUID) async {
        let channel = bridges.withLockedValue { $0[id] }
        try? await channel?.close()
    }

    /// Stops listening. Open connections end as their clients leave.
    public func stop() async {
        let open = channels.withLockedValue { list in
            defer { list = [] }
            return list
        }
        for channel in open { try? await channel.close() }
    }
}

/// One JSON message per line, both ways.
private final class LineHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let handle: MCPListener.Handle
    private let ended: MCPListener.Ended
    let id = UUID()
    private var pending = ByteBuffer()

    init(handle: @escaping MCPListener.Handle, ended: @escaping MCPListener.Ended) {
        self.handle = handle
        self.ended = ended
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pending.writeBuffer(&buffer)
        let channel = context.channel
        while let newline = pending.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) {
            let length = newline - pending.readerIndex
            let line = Data(pending.readBytes(length: length) ?? [])
            pending.moveReaderIndex(forwardBy: 1)
            guard !line.allSatisfy({ $0 == 32 || $0 == 13 }) else { continue }
            let incoming = MCPIncoming(body: line, transport: .socket(id))
            let handle = self.handle
            Task {
                let reply = await handle(incoming)
                guard var body = reply.body else { return }
                body.append(10)
                channel.writeAndFlush(ByteBuffer(bytes: body), promise: nil)
            }
        }
        pending.discardReadBytes()
    }

    func channelInactive(context: ChannelHandlerContext) {
        let ended = self.ended
        let id = self.id
        Task { await ended(.socket(id)) }
        context.fireChannelInactive()
    }
}

/// Streamable HTTP: POST /mcp with one JSON-RPC message, answered with JSON
/// (no event streams); DELETE /mcp ends a session.
private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let handle: MCPListener.Handle
    private let ended: MCPListener.Ended
    private let tokens: @Sendable () -> [String: Bool]
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    /// Requests larger than this are refused, so a runaway client can't fill memory.
    private static let limit = 8 * 1024 * 1024

    init(handle: @escaping MCPListener.Handle, ended: @escaping MCPListener.Ended, tokens: @escaping @Sendable () -> [String: Bool]) {
        self.handle = handle
        self.ended = ended
        self.tokens = tokens
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let request):
            head = request
            body.clear()
        case .body(var chunk):
            if body.readableBytes + chunk.readableBytes <= Self.limit { body.writeBuffer(&chunk) }
        case .end:
            guard let request = head else { return }
            head = nil
            respond(to: request, body: Data(body.readBytes(length: body.readableBytes) ?? []), context: context)
        }
    }

    private func respond(to request: HTTPRequestHead, body: Data, context: ChannelHandlerContext) {
        var headers: [String: String] = [:]
        for (name, value) in request.headers { headers[name.lowercased()] = value }
        let port = context.channel.localAddress?.port ?? 0
        let channel = context.channel
        let keepAlive = request.isKeepAlive
        if let refusal = MCPHTTPPolicy.refusal(method: request.method.rawValue, path: request.uri, headers: headers,
                                               tokens: tokens(), port: port) {
            let json = MCPRouterError.json(refusal.message)
            var extra: [(String, String)] = []
            if refusal.status == 401 { extra.append(("WWW-Authenticate", "Bearer")) }
            if refusal.status == 405 { extra.append(("Allow", "POST, DELETE")) }
            Self.send(channel, status: refusal.status, body: json, extra: extra, keepAlive: keepAlive)
            return
        }
        let session = headers["mcp-session-id"]
        if request.method == .DELETE {
            let ended = self.ended
            Task {
                await ended(.http(session: session))
                Self.send(channel, status: 204, body: nil, extra: [], keepAlive: keepAlive)
            }
            return
        }
        guard body.count < Self.limit else {
            Self.send(channel, status: 413, body: MCPRouterError.json("The message is larger than 8 MB."), extra: [], keepAlive: keepAlive)
            return
        }
        let handle = self.handle
        let incoming = MCPIncoming(body: body, transport: .http(session: session), token: MCPHTTPPolicy.fingerprint(headers))
        Task {
            let reply = await handle(incoming)
            var extra: [(String, String)] = []
            if let id = reply.session { extra.append(("Mcp-Session-Id", id)) }
            if let status = reply.status {
                Self.send(channel, status: status, body: reply.body, extra: extra, keepAlive: keepAlive)
            } else if let body = reply.body {
                Self.send(channel, status: 200, body: body, extra: extra, keepAlive: keepAlive)
            } else {
                Self.send(channel, status: 202, body: nil, extra: extra, keepAlive: keepAlive)
            }
        }
    }

    private static func send(_ channel: any Channel, status: Int, body: Data?, extra: [(String, String)], keepAlive: Bool) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: String(body?.count ?? 0))
        if body != nil { headers.add(name: "Content-Type", value: "application/json") }
        headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        for (name, value) in extra { headers.add(name: name, value: value) }
        let head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: headers)
        channel.eventLoop.execute {
            channel.write(HTTPServerResponsePart.head(head), promise: nil)
            if let body { channel.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil) }
            let done = channel.writeAndFlush(HTTPServerResponsePart.end(nil))
            if !keepAlive { done.whenComplete { _ in channel.close(promise: nil) } }
        }
    }
}

enum MCPRouterError {
    /// A JSON-RPC error with no id, for refusals before a message is read.
    static func json(_ message: String) -> Data {
        JSONValue.object(["jsonrpc": "2.0", "id": .null, "error": ["code": -32000, "message": .string(message)]]).data
    }
}
