import Foundation

/// One row of SHOW PROCESSLIST (S-053): a connection to the server and what it is doing.
public struct ServerProcess: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var user: String
    public var host: String
    public var database: String?
    public var command: String
    /// Seconds in the current state.
    public var time: Int
    public var state: String
    /// The statement running, cut to 100 characters unless the list is FULL; nil when idle.
    public var info: String?

    public init(id: Int64, user: String, host: String, database: String? = nil, command: String, time: Int,
                state: String = "", info: String? = nil) {
        self.id = id
        self.user = user
        self.host = host
        self.database = database
        self.command = command
        self.time = time
        self.state = state
        self.info = info
    }

    /// Reads SHOW [FULL] PROCESSLIST.
    public static func processes(_ result: StatementResult) -> [ServerProcess] {
        result.rows.indices.compactMap { row in
            guard let id = result.string(row, "Id").flatMap(Int64.init) else { return nil }
            return ServerProcess(id: id, user: result.string(row, "User") ?? "", host: result.string(row, "Host") ?? "",
                                 database: result.string(row, "db"), command: result.string(row, "Command") ?? "",
                                 time: result.string(row, "Time").flatMap { Int(Double($0) ?? 0) } ?? 0,
                                 state: result.string(row, "State") ?? "", info: result.string(row, "Info"))
        }
    }

    /// The processes with `text` in any column, ignoring case; all for empty text.
    public static func filter(_ processes: [ServerProcess], _ text: String) -> [ServerProcess] {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return processes }
        return processes.filter { process in
            process.columns.contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    public static let columnTitles = ["ID", "User", "Host", "Database", "Command", "Time", "State", "Info"]

    /// The row as text, in `columnTitles` order.
    public var columns: [String] {
        [String(id), user, host, database ?? "", command, String(time), state, info ?? ""]
    }

    /// Copy and Save As…: a header line, then one tab-separated line per process.
    public static func text(_ processes: [ServerProcess]) -> String {
        ([columnTitles] + processes.map(\.columns)).map {
            $0.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
    }

    /// KILL QUERY stops the statement and keeps the connection; KILL CONNECTION closes it.
    public static func killSQL(_ id: Int64, connection: Bool) -> String {
        (connection ? "KILL CONNECTION " : "KILL QUERY ") + String(id)
    }

    /// Whether Kill Query has anything to stop.
    public var isRunning: Bool { command == "Query" || command == "Execute" }
}

extension DatabaseClient {
    /// SHOW PROCESSLIST, or SHOW FULL PROCESSLIST for the whole statements.
    public func processes(full: Bool) async throws -> [ServerProcess] {
        ServerProcess.processes(try await run(full ? "SHOW FULL PROCESSLIST" : "SHOW PROCESSLIST"))
    }

    /// Kill Query or Kill Connection. Throws the server's error (no such thread, not your thread).
    public func kill(_ id: Int64, connection: Bool) async throws {
        _ = try await run(ServerProcess.killSQL(id, connection: connection))
    }
}
