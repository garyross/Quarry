import Foundation

/// MCP Activity (S-065): one request an agent made, as the window lists it.
/// Only the statement and the agent's message are kept, never result rows.
public struct ActivityRecord: Identifiable, Equatable, Sendable {
    public enum Status: String, CaseIterable, Sendable {
        case ok, error, denied

        public var title: String {
            switch self {
            case .ok: "OK"
            case .error: "Error"
            case .denied: "Denied"
            }
        }
    }

    public var id: UUID
    public var date: Date
    /// "claude-code 2.1.0".
    public var client: String
    public var token: String
    public var tokenID: UUID?
    public var connection: String
    public var database: String
    /// The tool, or "resources/read".
    public var tool: String
    public var statement: String
    public var status: Status
    /// The agent's error message; empty when it worked.
    public var message: String
    public var duration: TimeInterval

    public init(id: UUID = UUID(), date: Date, client: String, token: String, tokenID: UUID? = nil, connection: String,
                database: String, tool: String, statement: String, status: Status, message: String = "", duration: TimeInterval) {
        self.id = id
        self.date = date
        self.client = client
        self.token = token
        self.tokenID = tokenID
        self.connection = connection
        self.database = database
        self.tool = tool
        self.statement = statement
        self.status = status
        self.message = message
        self.duration = duration
    }

    /// "12 ms", "1.4 s".
    public var durationText: String {
        duration < 1 ? "\(Int((duration * 1000).rounded())) ms" : String(format: "%.1f s", duration)
    }
}

/// How far back the window looks.
public enum ActivityRange: String, CaseIterable, Sendable {
    case day, week, month, all

    public var title: String {
        switch self {
        case .day: "Last 24 Hours"
        case .week: "Last 7 Days"
        case .month: "Last 30 Days"
        case .all: "All Time"
        }
    }

    /// The oldest date shown, or nil for all.
    public func cutoff(from now: Date) -> Date? {
        switch self {
        case .day: now.addingTimeInterval(-86_400)
        case .week: now.addingTimeInterval(-7 * 86_400)
        case .month: now.addingTimeInterval(-30 * 86_400)
        case .all: nil
        }
    }
}

/// What MCP Activity's toolbar picks: text, time range and token.
public struct ActivityFilter: Equatable, Sendable {
    public var text: String
    public var range: ActivityRange
    /// Only this token's requests; nil for every token.
    public var token: String?

    public init(text: String = "", range: ActivityRange = .all, token: String? = nil) {
        self.text = text
        self.range = range
        self.token = token
    }

    public func matches(_ record: ActivityRecord, now: Date = .now) -> Bool {
        if let cutoff = range.cutoff(from: now), record.date < cutoff { return false }
        if let token, record.token != token { return false }
        let words = text.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [record.client, record.token, record.connection, record.database, record.tool, record.statement,
                        record.status.title, record.message].joined(separator: "\n").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    /// The matching records, newest first.
    public func apply(_ records: [ActivityRecord], now: Date = .now) -> [ActivityRecord] {
        records.filter { matches($0, now: now) }.sorted { $0.date > $1.date }
    }
}

public enum AgentActivity {
    /// How long requests are kept.
    public static let keepDays = 30

    /// The date before which requests are dropped.
    public static func retentionCutoff(now: Date = .now) -> Date {
        now.addingTimeInterval(-Double(keepDays) * 86_400)
    }

    /// The text of Export CSV…: a header, then one line per record, ISO 8601 times, CRLF as RFC 4180 says.
    public static func csv(_ records: [ActivityRecord]) -> String {
        let header = ["Time", "Client", "Token", "Connection", "Database", "Tool", "Statement", "Status", "Message", "Duration (ms)"]
        let time = ISO8601DateFormatter()
        let lines = records.map { record in
            [time.string(from: record.date), record.client, record.token, record.connection, record.database, record.tool,
             record.statement, record.status.title, record.message, String(Int((record.duration * 1000).rounded()))]
        }
        return ([header] + lines).map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// What a tool call shows in the Statement column when it ran no SQL of its own:
    /// its arguments, without connection and database (they have their own columns).
    public static func summary(_ arguments: [String: JSONValue]) -> String {
        arguments.filter { !["connection", "database"].contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.string ?? $0.value.text)" }
            .joined(separator: ", ")
    }
}
