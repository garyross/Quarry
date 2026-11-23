import Foundation

extension DatabaseClient {
    /// A batched INSERT or REPLACE stops growing at this many bytes or records,
    /// well under the server's smallest max_allowed_packet.
    public static let csvBatchBytes = 512 * 1024
    public static let csvBatchRows = 1000

    /// Imports the CSV file `reader` reads into `table` (S-045), as `mapping`
    /// says: INSERT and REPLACE go in batches of records, UPDATE one record at
    /// a time. `skipHeader` drops the first record, the field names. Run it on
    /// a `secondConnection()`. `onError` decides what happens after a
    /// statement fails; cancelling stops between statements, and what ran stays.
    public func importCSV(from reader: DumpReader, parser: CSVStreamParser, skipHeader: Bool,
                          mapping: CSVMapping, table: String, database: String,
                          onError: @Sendable (ImportFailure) async -> ImportErrorChoice,
                          progress: @Sendable (ImportProgress) -> Void) async throws -> ImportSummary {
        var parser = parser
        var run = CSVRun(report: ImportProgress(totalBytes: reader.totalBytes, rows: 0))
        var headerLeft = skipHeader
        /// Records read so far, the header not counted.
        var record = 0
        var batch = ""
        var batchFirst = 0
        var batchCount = 0
        let prefix = mapping.insertPrefix(table: table, database: database)
        progress(run.report)

        reading: while true {
            try Task.checkCancellation()
            let chunk = try reader.read()
            let records = try chunk.map { try parser.append($0) } ?? parser.finish()
            for row in records {
                if headerLeft {
                    headerLeft = false
                    continue
                }
                record += 1
                if mapping.method == .update {
                    let sql = mapping.update(row, table: table, database: database)
                    guard try await send(sql, first: record, count: 1, run: &run, onError: onError) else { break reading }
                    continue
                }
                if batchCount == 0 { batchFirst = record } else { batch += ", " }
                batch += mapping.tuple(row)
                batchCount += 1
                if batchCount >= Self.csvBatchRows || batch.utf8.count >= Self.csvBatchBytes {
                    let sql = prefix + batch
                    batch = ""
                    defer { batchCount = 0 }
                    guard try await send(sql, first: batchFirst, count: batchCount, run: &run, onError: onError)
                    else { break reading }
                }
            }
            run.report.statements = run.summary.statements
            run.report.rows = record
            run.report.bytesRead = reader.bytesRead
            progress(run.report)
            if chunk == nil {
                if batchCount > 0 {
                    _ = try await send(prefix + batch, first: batchFirst, count: batchCount, run: &run, onError: onError)
                }
                break
            }
        }
        run.report.statements = run.summary.statements
        run.report.rows = record
        progress(run.report)
        return run.summary
    }

    /// What a CSV import has done so far.
    private struct CSVRun {
        var report: ImportProgress
        var summary = ImportSummary()
        var skipAll = false
    }

    /// Runs one statement holding `count` records from `first`; false to stop.
    private func send(_ sql: String, first: Int, count: Int, run: inout CSVRun,
                      onError: @Sendable (ImportFailure) async -> ImportErrorChoice) async throws -> Bool {
        try Task.checkCancellation()
        run.summary.statements += 1
        guard let problem = await execute(sql) else {
            run.summary.rows += count
            return true
        }
        try Task.checkCancellation()
        if wasLost {
            throw DatabaseError(message: "The connection was lost after \(run.summary.rows.formatted()) rows. "
                                + "What ran stays in the database.")
        }
        let label = count == 1 ? "Row \(first.formatted())"
            : "Rows \(first.formatted())–\((first + count - 1).formatted())"
        let failure = ImportFailure(number: run.summary.statements, statement: String(sql.prefix(200)),
                                    message: problem.message, label: label)
        run.summary.failures.append(failure)
        run.report.errors = run.summary.failures.count
        guard !run.skipAll else { return true }
        switch await onError(failure) {
        case .continue: return true
        case .skipAll:
            run.skipAll = true
            return true
        case .stop:
            run.summary.stopped = true
            return false
        }
    }

    /// The first `limit` records of a CSV file, for the mapping's preview,
    /// and whether the file holds more.
    public static func previewCSV(_ url: URL, options: DataExport.CSVOptions, encoding: String.Encoding,
                                  limit: Int) throws -> (records: [CSVRow], more: Bool) {
        let reader = try DumpReader(url: url)
        defer { reader.close() }
        var parser = CSVStreamParser(options: options, encoding: encoding)
        var records: [CSVRow] = []
        while records.count <= limit {
            guard let chunk = try reader.read() else {
                records += try parser.finish()
                break
            }
            records += try parser.append(chunk)
        }
        return (Array(records.prefix(limit)), records.count > limit)
    }
}
