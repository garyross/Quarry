import Foundation
import QuarryKit
import SwiftData

/// One request an agent made through the MCP server, kept 30 days for MCP
/// Activity (S-065). Only the statement and the agent's message, never rows.
@Model
final class AgentRequest {
    var uid: UUID = UUID()
    var date: Date = Date.now
    var client: String = ""
    var token: String = ""
    var tokenID: UUID?
    var connection: String = ""
    var database: String = ""
    var tool: String = ""
    var statement: String = ""
    /// `ActivityRecord.Status`'s raw value.
    var status: String = ActivityRecord.Status.ok.rawValue
    var message: String = ""
    var duration: Double = 0

    init(_ record: ActivityRecord) {
        uid = record.id
        date = record.date
        client = record.client
        token = record.token
        tokenID = record.tokenID
        connection = record.connection
        database = record.database
        tool = record.tool
        statement = record.statement
        status = record.status.rawValue
        message = record.message
        duration = record.duration
    }

    var record: ActivityRecord {
        ActivityRecord(id: uid, date: date, client: client, token: token, tokenID: tokenID, connection: connection, database: database,
                       tool: tool, statement: statement, status: ActivityRecord.Status(rawValue: status) ?? .ok, message: message,
                       duration: duration)
    }
}

/// What one request touched, filled in as its tool runs (S-065): the
/// connection and database it resolved, and the SQL it sent.
final class ActivityTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: (connection: String, database: String, statement: String) = ("", "", "")

    var connection: String {
        get { lock.withLock { values.connection } }
        set { lock.withLock { values.connection = newValue } }
    }
    var database: String {
        get { lock.withLock { values.database } }
        set { lock.withLock { values.database = newValue } }
    }
    var statement: String {
        get { lock.withLock { values.statement } }
        set { lock.withLock { values.statement = newValue } }
    }

    /// The request being traced, if any.
    @TaskLocal static var current: ActivityTrace?
}

extension AppModel {
    /// Reads the last 30 days, dropping anything older (at launch, and hourly as requests come).
    func reloadAgentActivity() {
        pruneAgentActivity()
        let descriptor = FetchDescriptor<AgentRequest>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        agentActivity = ((try? context.fetch(descriptor)) ?? []).map(\.record)
        lastActivityPrune = .now
    }

    /// Keeps one request.
    func logAgentRequest(_ record: ActivityRecord) {
        context.insert(AgentRequest(record))
        try? context.save()
        agentActivity.insert(record, at: 0)
        if Date.now.timeIntervalSince(lastActivityPrune) > 3600 { reloadAgentActivity() }
    }

    /// Clear Activity: everything before `date`, or all with nil.
    func clearAgentActivity(before date: Date?) {
        if let date {
            try? context.delete(model: AgentRequest.self, where: #Predicate { $0.date < date })
        } else {
            try? context.delete(model: AgentRequest.self)
        }
        try? context.save()
        reloadAgentActivity()
    }

    private func pruneAgentActivity() {
        let cutoff = AgentActivity.retentionCutoff()
        try? context.delete(model: AgentRequest.self, where: #Predicate { $0.date < cutoff })
        try? context.save()
    }
}
