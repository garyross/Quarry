import Foundation
import NIOConcurrencyHelpers

/// Rows an agent asked for (S-063): a window of the result, and how many there were.
public struct AgentRows: Sendable {
    public var columns: [ResultColumn]
    public var rows: [[CellValue]]
    /// Every row the statement returned, also those outside the window.
    public var total: Int
    /// Rows changed, for statements that return none.
    public var affectedRows: Int?
    public var duration: Duration

    /// The window as JSON: columns, rows (arrays in column order), and paging.
    public func json(offset: Int, cellLimit: Int = AgentRows.cellLimit) -> JSONValue {
        if let affectedRows, columns.isEmpty {
            return ["affectedRows": .int(affectedRows), "seconds": .double(Self.seconds(duration))]
        }
        var result: [String: JSONValue] = [
            "columns": .array(columns.map { column in
                var info: [String: JSONValue] = ["name": .string(column.name), "type": .string(column.typeName)]
                if !column.table.isEmpty { info["table"] = .string(column.table) }
                return .object(info)
            }),
            "rows": .array(rows.map { row in .array(zip(row, columns).map { Self.value($0, $1, limit: cellLimit) }) }),
            "rowCount": .int(rows.count),
            "totalRows": .int(total),
            "offset": .int(offset),
            "seconds": .double(Self.seconds(duration)),
        ]
        if offset + rows.count < total { result["nextOffset"] = .int(offset + rows.count) }
        return .object(result)
    }

    /// Text longer than this is cut, with a note, so one cell can't flood an agent.
    public static let cellLimit = 16_384

    /// NULL as null, whole numbers as numbers, decimals and text as strings, bytes as hex.
    static func value(_ cell: CellValue, _ column: ResultColumn, limit: Int) -> JSONValue {
        switch cell {
        case .null: return .null
        case .flag(let on): return .bool(on)
        case .text(let text):
            if column.isNumeric, column.bitWidth == nil, let number = Int(text) { return .int(number) }
            guard text.count > limit else { return .string(text) }
            return .string(String(text.prefix(limit)) + "… (\(text.count) characters; cut at \(limit))")
        case .binary(let data):
            let shown = data.prefix(limit / 2).map { String(format: "%02X", $0) }.joined()
            return .string("0x" + shown + (data.count > limit / 2 ? "… (\(data.count) bytes)" : ""))
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return ((Double(seconds) + Double(attoseconds) / 1e18) * 1000).rounded() / 1000
    }
}

extension DatabaseClient {
    /// Locks an agent's connection to a SQLite file down (S-073): no ATTACH, and with
    /// `readOnly` SQLite's `query_only`. A server's connection needs nothing here.
    public func restrictForAgent(readOnly: Bool) async throws {
        guard let sqlite = driver as? SQLiteDriver else { return }
        try await sqlite.restrictForAgent(queryOnly: readOnly)
    }

    /// Runs one read inside the dialect's read-only transaction (START TRANSACTION READ ONLY), so the server refuses
    /// any write it tries, then rolls back. Keeps rows `offset..<offset+limit`
    /// and counts the rest. Check the SQL with `AgentSQL.readProblem` first.
    public func agentRead(_ sql: String, in database: String?, offset: Int, limit: Int) async throws -> AgentRows {
        await acquire()
        defer { release() }
        try await useForAgent(database)
        do {
            _ = try await driver.execute(dialect.readOnlyBeginSQL, encoding: viewEncoding)
        } catch {
            throw logged(failure(error))
        }
        do {
            let rows = try await stream(sql, offset: offset, limit: limit)
            _ = try? await driver.execute(dialect.rollbackSQL, encoding: viewEncoding)
            return rows
        } catch {
            _ = try? await driver.execute(dialect.rollbackSQL, encoding: viewEncoding)
            throw error
        }
    }

    /// Runs one statement that may change data. Rows it returns are windowed like a read.
    public func agentWrite(_ sql: String, in database: String?, offset: Int = 0, limit: Int = 1000) async throws -> AgentRows {
        await acquire()
        defer { release() }
        try await useForAgent(database)
        var rows = try await stream(sql, offset: offset, limit: limit)
        if rows.columns.isEmpty, !Self.returnsRows(sql) {
            rows.affectedRows = (try? await driver.affectedRows()) ?? 0
        }
        return rows
    }

    /// USE `database` while the caller holds the connection, so two agent calls
    /// can't swap databases between a USE and its statement.
    private func useForAgent(_ database: String?) async throws {
        guard let database, !database.isEmpty else { return }
        if let use = dialect.useSQL(database) { _ = try await perform(use, countingRows: false) }
    }

    /// Reads rows as they arrive, keeping only the window, so a large result
    /// never sits in memory whole. Logs the statement to the Console.
    private func stream(_ sql: String, offset: Int, limit: Int) async throws -> AgentRows {
        let clock = ContinuousClock()
        let start = clock.now
        log(sql)
        let encoding = viewEncoding
        let state = NIOLockedValueBox(StreamState())
        do {
            try await driver.stream(sql, encoding: encoding) { columns, cells in
                state.withLockedValue { state in
                    if state.columns == nil { state.columns = columns() }
                    if state.total >= offset, state.rows.count < limit {
                        state.rows.append(cells())
                    }
                    state.total += 1
                }
            }
        } catch {
            throw logged(failure(error))
        }
        let done = state.withLockedValue { $0 }
        return AgentRows(columns: done.columns ?? [], rows: done.rows, total: done.total, affectedRows: nil,
                         duration: clock.now - start)
    }
}

private struct StreamState {
    var columns: [ResultColumn]?
    var rows: [[CellValue]] = []
    var total = 0
}
