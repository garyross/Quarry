import Foundation
import QuarryKit

/// The Query view: Run Current Statement (⌘R), Run All (⌥⌘R) and Cancel Query (⌘.).
extension Session {
    func runCurrentStatement() {
        let statements = StatementSplitter.split(query.text)
        guard let statement = StatementSplitter.statement(at: query.cursor, in: statements) else {
            query.status = "Type SQL and press ⌘R to run it."
            return
        }
        run([statement])
    }

    func runAll() {
        let statements = StatementSplitter.split(query.text)
        guard !statements.isEmpty else {
            query.status = "Type SQL and press ⌘R to run it."
            return
        }
        run(statements)
    }

    /// Runs in order and stops at the first error; earlier results stay visible.
    private func run(_ statements: [SQLStatement]) {
        guard let client, phase == .connected, !query.isRunning else { return }
        recordHistory(statements)
        query.isRunning = true
        query.isCancelling = false
        query.error = nil
        query.errorLine = nil
        let clock = ContinuousClock()
        let start = clock.now
        currentLoad = Task {
            var ran = 0
            var last: StatementResult?
            var lastWithRows: StatementResult?
            var statementWithRows = ""
            for statement in statements {
                if query.isCancelling { break }
                do {
                    let result = try await client.run(statement.text)
                    // SLEEP() and some reads end normally when killed; the result is not the answer.
                    if query.isCancelling { break }
                    ran += 1
                    last = result
                    if result.returnsRows {
                        lastWithRows = result
                        statementWithRows = statement.text
                    }
                } catch {
                    let problem = DatabaseError.from(error)
                    if query.isCancelling || problem.code == DatabaseClient.queryInterruptedCode { break }
                    query.error = problem
                    query.errorLine = ServerMessage.line(in: problem.message).map { statement.line + $0 - 1 } ?? statement.line
                    break
                }
            }
            if let shown = lastWithRows ?? last {
                let (grid, editing, fields) = await queryResults(for: shown, client: client)
                query.results = grid
                query.editing = editing
                query.resultFields = fields
                query.editError = nil
                query.resultTable = RowCopy.insertTable(for: shown.columns)
                query.resultColumns = shown.columns
                query.resultStatement = lastWithRows == nil ? (statements.last?.text ?? "") : statementWithRows
            }
            if query.isCancelling {
                query.status = StatementResult.cancelledStatus(ran: ran, of: statements.count, after: clock.now - start)
            } else if let last {
                query.status = statements.count > 1
                    ? "\(StatementResult.formatCount(ran, "statement")) · last: \(last.summary)"
                    : last.summary
            } else {
                query.status = ""
            }
            query.isRunning = false
            query.isCancelling = false
            // CREATE, ALTER, DROP and the like may have changed what completes.
            if ran > 0, statements.prefix(ran).contains(where: { !DatabaseClient.returnsRows($0.text) }) {
                refreshCompletionCatalog()
            }
            // A USE statement changes the database: follow it in the sidebar.
            if let current = try? await client.currentDatabase(),
               current != database, databases.contains(current) {
                database = current
            }
        }
    }

    /// Cancel Query (⌘.): stops the running statement on the server and runs
    /// no more of a Run All. The connection stays open (S-036).
    func cancelQuery() {
        guard let client, query.isRunning, !query.isCancelling else { return }
        query.isCancelling = true
        Task {
            do {
                try await client.cancelRunningQuery()
            } catch {
                // The statement keeps running; say why and let Cancel be pressed again.
                guard query.isRunning else { return }
                query.isCancelling = false
                query.error = DatabaseError(message: "Could not cancel the query: \(DatabaseError.from(error).message)",
                                            suggestion: "Wait for it to finish, or close the window to drop the connection.")
            }
        }
    }

    /// Clicking the error bar moves the cursor to the error's line.
    func revealErrorLine() {
        guard let line = query.errorLine else { return }
        let text = query.text as NSString
        var location = 0
        var current = 1
        while current < line, location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            current += 1
        }
        query.selectRequest = NSRange(location: min(location, text.length), length: 0)
    }
}
