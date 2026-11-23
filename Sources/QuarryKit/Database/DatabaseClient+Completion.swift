import Foundation

extension DatabaseClient {
    /// A database's tables and views with their columns, for the query
    /// editor's completions (S-031). Two information_schema reads.
    public func completionTables(in database: String) async throws -> [CompletionCatalog.Table] {
        if dialect.engine == .sqlite {
            // A file is small enough to ask each table (S-068).
            var tables: [CompletionCatalog.Table] = []
            for object in try await tablesAndViews(in: database) {
                let fields = try await fields(of: object.name, in: database)
                tables.append(CompletionCatalog.Table(name: object.name, isView: object.kind == .view,
                                                      columns: fields.map { .init(name: $0.name, type: $0.fullType) }))
            }
            return tables
        }
        let schema = SQLQuote.mysqlLiteral(database)
        let tables = try await run("""
            SELECT TABLE_NAME AS name, TABLE_TYPE AS type FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = \(schema) ORDER BY TABLE_NAME
            """)
        let columns = try await run("""
            SELECT TABLE_NAME AS t, COLUMN_NAME AS c, COLUMN_TYPE AS y FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = \(schema) ORDER BY TABLE_NAME, ORDINAL_POSITION
            """)
        var byTable: [String: [CompletionCatalog.Column]] = [:]
        for row in columns.rows.indices {
            guard let table = columns.string(row, "t"), let name = columns.string(row, "c") else { continue }
            byTable[table, default: []].append(.init(name: name, type: columns.string(row, "y") ?? ""))
        }
        return tables.rows.indices.compactMap { row in
            guard let name = tables.string(row, "name") else { return nil }
            let type = tables.string(row, "type") ?? ""
            return CompletionCatalog.Table(name: name, isView: type.contains("VIEW"), columns: byTable[name] ?? [])
        }
    }
}
