import Foundation
import QuarryKit
import QuarryControllers

/// Editing query results (S-035): a cell saves with an UPDATE on its table's
/// primary key, then that row is read back so the server's value shows.
extension Session {
    /// The results to show for `result`, with which cells can be edited. Looks
    /// up each source table's primary key (SHOW FULL COLUMNS); a table that
    /// can't be looked up stays read-only.
    func queryResults(for result: StatementResult, client: DatabaseClient) async -> (GridData, ResultEditing, [FieldInfo?]) {
        guard result.returnsRows, !result.rows.isEmpty else { return (result.returnsRows ? GridData(result) : .empty, .none, []) }
        var keys: [ResultEditing.Source: [String]] = [:]
        var fields: [ResultEditing.Source: [FieldInfo]] = [:]
        // A wide JOIN names few tables; past a handful, the lookups would slow every run.
        for source in ResultEditing.sources(of: result.columns).prefix(8) {
            guard let list = try? await client.fields(of: source.table, in: source.database) else { continue }
            fields[source] = list
            keys[source] = list.filter { $0.key == "PRI" }.map(\.name)
        }
        let editing = ResultEditing(columns: result.columns, primaryKeys: keys, engine: client.dialect.engine)
        var grid = GridData(result)
        for index in grid.columns.indices { grid.columns[index].help = editing.reason(column: index) }
        if client.dialect.engine == .sqlite {
            // S-069: a value stored with another type than its column's says so on hover.
            for index in grid.columns.indices where index < result.columns.count && !result.columns[index].typeName.isEmpty {
                grid.columns[index].affinity = SQLiteAffinity(result.columns[index].typeName)
            }
        }
        let info: [FieldInfo?] = result.columns.indices.map { index in
            guard let source = editing.source(column: index) else { return nil }
            let name = result.columns[index].orgName
            return fields[source]?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        return (grid, editing, info)
    }

    func canEditQueryCell(row: Int, column: Int) -> Bool {
        !query.isRunning && !isReadOnly && row < query.results.rows.count && column < query.results.rows[row].count
            && query.editing.source(column: column) != nil
    }

    /// Long values, bytes, JSON and BIT open in the Field or Bit Editor rather than inline.
    func queryCellOpensEditor(row: Int, column: Int) -> Bool {
        let results = query.results
        guard row < results.rows.count, column < results.rows[row].count, column < results.columns.count else { return false }
        if results.columns[column].bitWidth != nil { return true }
        return LongValue.opensFieldEditor(results.rows[row][column], fieldType: queryField(column)?.baseType)
    }

    func queryField(_ column: Int) -> FieldInfo? {
        column < query.resultFields.count ? query.resultFields[column] : nil
    }

    /// Saves one result cell. The grid shows the new value at once; a failed
    /// UPDATE puts the old row back and shows why.
    func editQueryCell(row: Int, column: Int, to value: CellValue) {
        guard let client, canEditQueryCell(row: row, column: column) else { return }
        let editing = query.editing
        let old = query.results.rows[row]
        let unchanged = value.isNull ? old[column].isNull : value == old[column] || value.plainText == (old[column].plainText ?? "")
        guard !unchanged, let sql = editing.updateSQL(row: old, column: column, value: value),
              let source = editing.source(column: column) else { return }
        let edited = editing.applying(value, column: column, to: old)
        query.editError = nil
        replaceQueryRows(matching: old, source: source, editing: editing) { _ in edited }
        let revision = query.results.revision
        currentLoad = Task {
            do {
                let result = try await client.run(sql)
                if result.affectedRows == 0 {
                    query.editError = DatabaseError(message: "No row was changed.",
                                                    suggestion: "The value may equal the old one, or the row was changed or deleted elsewhere. Run the query again to see it.")
                }
                // Read the row back by its key as it is now (the key itself may have changed).
                guard let refetch = editing.refetchSQL(source: source, row: edited),
                      let stored = try await client.run(refetch).rows.first,
                      query.results.revision == revision else { return }
                let groups = editing.refetchColumns(source: source)
                replaceQueryRows(matching: edited, source: source, editing: editing) { row in
                    var row = row
                    for (value, indexes) in zip(stored, groups) {
                        for index in indexes where index < row.count { row[index] = value }
                    }
                    return row
                }
            } catch {
                query.editError = DatabaseError.from(error)
                guard query.results.revision == revision else { return }
                replaceQueryRows(matching: edited, source: source, editing: editing) { row in
                    var row = row
                    for indexes in editing.refetchColumns(source: source) {
                        for index in indexes where index < row.count && index < old.count { row[index] = old[index] }
                    }
                    return row
                }
            }
        }
    }

    /// Changes every result row that shows the same row of `source` (a JOIN can repeat it).
    private func replaceQueryRows(matching key: [CellValue], source: ResultEditing.Source, editing: ResultEditing,
                                  _ change: ([CellValue]) -> [CellValue]) {
        let rows = query.results.rows.map { editing.sameRow($0, key, source: source) ? change($0) : $0 }
        query.results = GridData(columns: query.results.columns, rows: rows)
    }

    /// The Field or Bit Editor for a result cell, editable when its column is.
    func openQueryValue(row: Int, column: Int, typed: String? = nil) {
        let results = query.results
        guard row < results.rows.count, column < results.rows[row].count, column < results.columns.count else { return }
        let editable = canEditQueryCell(row: row, column: column)
        let field = queryField(column)
        if let width = results.columns[column].bitWidth {
            bitEditor = BitEditor(fieldName: results.columns[column].title, width: width, row: row, column: column,
                                  value: results.rows[row][column], isEditable: editable,
                                  isNullable: field?.isNullable ?? false) { [weak self] value in
                self?.bitEditor = nil
                self?.editQueryCell(row: row, column: column, to: value)
            }
            return
        }
        fieldEditor = FieldEditor(fieldName: results.columns[column].title, fieldType: field?.baseType, row: row,
                                  column: column, value: results.rows[row][column], typed: typed,
                                  isEditable: editable) { [weak self] _, value in
            self?.editQueryCell(row: row, column: column, to: value)
        }
    }
}
