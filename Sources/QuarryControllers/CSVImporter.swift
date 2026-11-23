import Foundation
import QuarryKit

/// The CSV half of the Import sheet (S-045): how the file is written, then
/// the field mapping, Sequel Pro's: which column fills each field of the
/// target table (or of a new one), INSERT, REPLACE or UPDATE, and a preview
/// of the file's first records. `Importer` runs it.
@MainActor @Observable
package final class CSVImporter {
    package enum Step { case options, mapping }

    package enum Target: Hashable {
        case table(String)
        case newTable
    }

    /// A field of a new table: its name and type, both editable.
    package struct NewField: Identifiable, Equatable {
        package let id: Int
        package var name: String
        package var type: String
    }

    /// How many records the mapping reads to preview and to guess new types.
    package nonisolated static let previewLimit = 100

    package var step = Step.options
    /// How the file is written; turning field names on or off redoes the mapping.
    package var format = CSVFormat() {
        didSet { if oldValue.header != format.header, step == .mapping { rebuild() } }
    }
    /// The file's first row holds field names.
    package var header: Bool { format.header }

    /// The file's first records, the field names included when `header` is on.
    package private(set) var records: [CSVRow] = []
    /// The file holds more records than the preview.
    package private(set) var hasMore = false
    package private(set) var tables: [String] = []
    package private(set) var target = Target.newTable
    /// The target asked for last, while its fields load.
    private var requested = Target.newTable
    package var newTableName = ""
    package private(set) var fields: [FieldInfo] = []
    package private(set) var newFields: [NewField] = []
    package private(set) var mapping: CSVMapping
    package private(set) var alignment = CSVMapping.Alignment.fileOrder
    /// The previewed record, 0-based among `dataRecords`.
    package var record = 0
    package private(set) var isLoading = false
    /// The connection's engine, for new tables' types and the SQL (S-071).
    package let engine: Engine
    package private(set) var loadError: String?

    package init(engine: Engine) {
        self.engine = engine
        mapping = CSVMapping(fields: [], columns: [], engine: engine)
    }

    package var options: DataExport.CSVOptions { format.options }

    /// The records to import: the preview without the field names.
    package var dataRecords: ArraySlice<CSVRow> { header ? records.dropFirst() : records[...] }

    package var columns: [String] {
        CSVMapping.columnNames(header: header ? records.first : nil,
                               count: records.map(\.count).max() ?? 0)
    }

    package var isNewTable: Bool { target == .newTable }

    package var tableName: String {
        switch target {
        case .table(let name): name
        case .newTable: newTableName.trimmingCharacters(in: .whitespaces)
        }
    }

    /// The type shown beside a field's name in the grid.
    package func type(of index: Int) -> String {
        if isNewTable { return newFields.indices.contains(index) ? newFields[index].type : "" }
        return fields.indices.contains(index) ? fields[index].fullType : ""
    }

    /// Why Import can't run yet, or nil.
    package var problem: String? {
        if isLoading { return "Reading the table’s fields…" }
        if let loadError { return loadError }
        if isNewTable {
            if tableName.isEmpty { return "Name the new table." }
            if let problem = NewTable.problem(with: tableName, existing: tables) { return problem }
            if newFields.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return "Name every field of the new table."
            }
            if newFields.contains(where: { $0.type.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return "Give every field of the new table a type."
            }
        }
        return mapping.problem
    }

    /// "Record 1 of 100", "Record 1 of the first 100".
    package var recordText: String {
        let count = dataRecords.count
        guard count > 0 else { return "No records" }
        return "Record \((record + 1).formatted()) of \(hasMore ? "the first " : "")\(count.formatted())"
    }

    // The grid's rows may outlive a smaller mapping for a moment: every
    // lookup by row checks its index.

    package func fieldName(_ index: Int) -> String {
        mapping.fields.indices.contains(index) ? mapping.fields[index] : ""
    }

    package func source(of index: Int) -> Int? {
        mapping.sources.indices.contains(index) ? mapping.sources[index] : nil
    }

    package func isMatch(_ index: Int) -> Bool {
        mapping.fields.indices.contains(index) && mapping.matchFields.contains(mapping.fields[index])
    }

    /// The previewed record's value for a field: its text, "NULL", or "" when the field isn't imported.
    package func previewValue(for field: Int) -> String? {
        guard let column = source(of: field), dataRecords.indices.contains(dataRecords.startIndex + record) else {
            return ""
        }
        let row = dataRecords[dataRecords.startIndex + record]
        guard column < row.count else { return nil }
        return row[column]
    }

    // MARK: Loading

    /// Reads the preview and the database's tables, then shows the mapping.
    package func loadMapping(file: URL, encoding: String.Encoding, client: DatabaseClient, database: String,
                     preferredTable: String?) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let options = options
            let limit = Self.previewLimit + 1
            let preview = try await Task.detached {
                try DatabaseClient.previewCSV(file, options: options, encoding: encoding,
                                              limit: limit)
            }.value
            records = Array(preview.records.prefix(Self.previewLimit + (header ? 1 : 0)))
            hasMore = preview.more || preview.records.count > records.count
            record = 0
            tables = try await client.tablesAndViews(in: database).filter { $0.kind == .table }.map(\.name)
            if newTableName.isEmpty {
                newTableName = file.deletingPathExtension().lastPathComponent
                    .replacing(/[^A-Za-z0-9_]+/, with: "_")
            }
            alignment = header ? .matchingNames : .fileOrder
            let table = preferredTable.flatMap { tables.contains($0) ? $0 : nil } ?? tables.first
            await choose(table.map(Target.table) ?? .newTable, client: client, database: database)
            step = .mapping
        } catch {
            loadError = DatabaseError.from(error).message
        }
    }

    /// Picks the target table and lines its fields up with the file's columns.
    /// The grid keeps the old fields until the new ones are read, so it never
    /// shows a mapping and fields that disagree.
    package func choose(_ target: Target, client: DatabaseClient, database: String) async {
        requested = target
        loadError = nil
        var loaded: [FieldInfo] = []
        if case .table(let name) = target {
            isLoading = true
            do {
                loaded = try await client.fields(of: name, in: database)
            } catch {
                loadError = DatabaseError.from(error).message
            }
            guard requested == target else { return }
            isLoading = false
        }
        fields = loaded
        self.target = target
        rebuild()
    }

    /// Mapping from scratch: the fields of the target, aligned as chosen.
    private func rebuild() {
        let method = mapping.method
        let ignore = mapping.ignoreDuplicates
        record = min(record, max(0, dataRecords.count - 1))
        if isNewTable {
            newFields = columns.enumerated().map { index, name in
                let values = dataRecords.map { index < $0.count ? $0[index] : nil }
                return NewField(id: index, name: name, type: CSVMapping.guessType(values, engine: engine))
            }
            mapping = CSVMapping(fields: newFields.map(\.name), columns: columns, alignment: .fileOrder, engine: engine)
            mapping.ignoreDuplicates = ignore
            alignment = .fileOrder
            return
        }
        if alignment == .matchingNames, !header { alignment = .fileOrder }
        if alignment == .custom { alignment = header ? .matchingNames : .fileOrder }
        mapping = CSVMapping(fields: fields.map(\.name), columns: columns, alignment: alignment, engine: engine)
        mapping.method = method
        mapping.ignoreDuplicates = ignore
        mapping.matchFields = Set(fields.filter { $0.key == "PRI" }.map(\.name))
    }

    // MARK: Edits

    package func align(_ alignment: CSVMapping.Alignment) {
        self.alignment = alignment
        guard alignment != .custom else { return }
        mapping.sources = CSVMapping.align(alignment, columns: columns, fields: mapping.fields)
    }

    /// One field's column, picked by hand: the order becomes custom.
    package func setSource(_ column: Int?, for field: Int) {
        guard mapping.sources.indices.contains(field) else { return }
        mapping.sources[field] = column
        alignment = .custom
    }

    package func setMethod(_ method: CSVMapping.Method) { mapping.method = method }
    package func setIgnoreDuplicates(_ on: Bool) { mapping.ignoreDuplicates = on }

    package func setMatch(_ on: Bool, for field: Int) {
        guard mapping.fields.indices.contains(field) else { return }
        let name = mapping.fields[field]
        if on { mapping.matchFields.insert(name) } else { mapping.matchFields.remove(name) }
    }

    package func renameNewField(_ index: Int, to name: String) {
        guard newFields.indices.contains(index), mapping.fields.indices.contains(index) else { return }
        newFields[index].name = name
        mapping.fields[index] = name
    }

    package func setNewFieldType(_ index: Int, to type: String) {
        guard newFields.indices.contains(index) else { return }
        newFields[index].type = type
    }

    package func step(by offset: Int) {
        record = min(max(0, record + offset), max(0, dataRecords.count - 1))
    }

    /// The CREATE TABLE a new table needs, or nil for an existing table.
    package func createStatement(database: String) -> String? {
        guard isNewTable else { return nil }
        return CSVMapping.createTable(tableName, database: database,
                                      fields: newFields.map { ($0.name.trimmingCharacters(in: .whitespaces), $0.type) },
                                      engine: engine)
    }

    /// Format and separator from a file's extension: .tsv is tab-separated.
    package func adopt(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "tsv", "tab": format.separator = .tab
        case "csv": if format.separator == .tab { format.separator = .comma }
        default: break
        }
        step = .options
        newTableName = ""
        records = []
        loadError = nil
    }
}
