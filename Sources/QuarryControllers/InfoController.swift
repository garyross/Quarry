import Foundation
import Observation
import QuarryKit

/// Info (⌘5): an object's status and create statement; for a table, its
/// engine, character set, collation, auto-increment value and comment can
/// change, one ALTER TABLE each, as in Sequel Pro's extended table info (S-027).
@Observable
package final class InfoController {
    package init() {}

    package private(set) var load = LoadState()
    package private(set) var status: TableStatus?
    package private(set) var createStatement = ""
    package private(set) var kind: ObjectKind?
    /// How Content finds a SQLite table's rows when it has no primary key (S-069); nil otherwise.
    package private(set) var rowNote: String?
    /// A SQLite table's options, STRICT and WITHOUT ROWID; nil on a server or for a view (S-070).
    package private(set) var sqliteOptions: [String]?
    /// Engines the server supports and its character sets, loaded once per connection.
    package private(set) var engines: [String] = []
    package private(set) var catalog: CharsetCatalog?
    /// What the Comment and Auto Increment fields hold while they are typed in.
    package var comment = ""
    package var autoIncrementText = ""
    /// An engine waiting on the alert: the server rebuilds the table to change it.
    package var pendingEngine: String?
    package var isChanging = false
    /// Why a change failed, above the form; the controls show the table's real values again.
    package var editError: DatabaseError?

    package struct Target {
        package let client: DatabaseClient
        package let database: String
        package let object: DBObject
        package var key: String { "\(database)/\(object.id)" }
    }

    @ObservationIgnored package private(set) var target: Target?
    @ObservationIgnored private var optionsClient: DatabaseClient?

    package func reset() {
        target = nil
        status = nil
        createStatement = ""
        kind = nil
        rowNote = nil
        sqliteOptions = nil
        load = LoadState()
        clearEditState()
    }

    private func clearEditState() {
        pendingEngine = nil
        editError = nil
        comment = ""
        autoIncrementText = ""
    }

    package func invalidate() { load = LoadState() }

    // MARK: Loading

    package func show(_ object: DBObject, in database: String, client: DatabaseClient, force: Bool) -> Task<Void, Never>? {
        let next = Target(client: client, database: database, object: object)
        if next.key != target?.key { clearEditState() }
        target = next
        if !force, load.loadedFor == next.key { return nil }
        return Task { await withLoading({ self.load.isLoading = $0 }) { await self.reload(next) } }
    }

    package func reload(_ target: Target) async {
        do {
            let object = target.object
            let result = object.kind.hasRows ? try await target.client.tableStatus(of: object.name, in: target.database) : nil
            let create = try await target.client.createStatement(of: object, in: target.database)
            var note: String?
            if object.kind == .table, target.client.dialect.engine == .sqlite,
               let fields = try? await target.client.fields(of: object.name, in: target.database),
               !fields.contains(where: { $0.key == "PRI" }) {
                note = Self.rowIDNote
            }
            let options = object.kind == .table && target.client.dialect.engine == .sqlite
                ? SQLiteTable(sql: create)?.optionNames ?? [] : nil
            // Engines and character sets are MySQL's; a SQLite table has only STRICT and WITHOUT ROWID.
            if object.kind == .table, target.client.dialect.engine == .mysql, optionsClient !== target.client {
                engines = try await target.client.tableDefaults(in: target.database).engines
                catalog = try await target.client.charsetCatalog()
                optionsClient = target.client
            }
            guard self.target?.key == target.key else { return }
            status = result.flatMap(TableStatus.init)
            createStatement = create
            kind = object.kind
            rowNote = note
            sqliteOptions = options
            comment = status?.comment ?? ""
            autoIncrementText = status?.autoIncrement.map { String($0) } ?? ""
            load = LoadState(loadedFor: target.key)
        } catch {
            guard self.target?.key == target.key else { return }
            load = LoadState(error: DatabaseError.from(error))
        }
    }

    // MARK: What shows

    package static let rowIDNote = "Rows are found by rowid (no primary key)."

    package var tableName: String { target?.object.name ?? "" }

    package var canEdit: Bool {
        guard let target else { return false }
        return kind == .table && !target.client.isReadOnly && target.client.dialect.engine == .mysql
            && status != nil && load.loadedFor == target.key && !isChanging
    }

    package var charset: String { status?.charset(in: catalog) ?? "" }

    /// The engine menu, with the table's own engine even when the server no longer lists it.
    package var engineChoices: [String] {
        guard let engine = status?.engine, !engine.isEmpty,
              !engines.contains(where: { $0.caseInsensitiveCompare(engine) == .orderedSame }) else { return engines }
        return engines + [engine]
    }

    package var charsetChoices: [String] {
        let names = catalog?.charsets.map(\.name) ?? []
        return names.contains(charset) || charset.isEmpty ? names : names + [charset]
    }

    package var collationChoices: [String] {
        let names = catalog?.collations(for: charset) ?? []
        guard let collation = status?.collation, !collation.isEmpty, !names.contains(collation) else { return names }
        return names + [collation]
    }

    package var canResetAutoIncrement: Bool { canEdit && status?.autoIncrement != nil }

    /// Size and Dates, label and value, leaving out what the server didn't report.
    package var sizeDetails: [(label: String, value: String)] {
        guard let status else { return [] }
        func bytes(_ value: Int?) -> String { value.map(ByteCount.format) ?? "" }
        return [
            (sqliteOptions != nil ? "Rows" : "Rows (estimate)", status.rows.map { $0.formatted() } ?? ""), ("Row Format", status.rowFormat),
            ("Average Row Length", bytes(status.averageRowLength)), ("Data Size", bytes(status.dataLength)),
            ("Maximum Data Size", status.maxDataLength.flatMap { $0 > 0 ? ByteCount.format($0) : nil } ?? ""),
            ("Index Size", bytes(status.indexLength)), ("Free Space", bytes(status.dataFree)),
        ].filter { !$0.1.isEmpty }
    }

    package var dateDetails: [(label: String, value: String)] {
        guard let status else { return [] }
        return [("Created", status.created), ("Updated", status.updated)].filter { !$0.1.isEmpty }
    }

    // MARK: Changes

    /// The engine menu: asks first, since the server copies every row into a new table.
    package func requestEngine(_ engine: String) {
        guard canEdit, engine.caseInsensitiveCompare(status?.engine ?? "") != .orderedSame else { return }
        pendingEngine = engine
    }

    package func confirmEngine() -> Task<Void, Never>? {
        guard let engine = pendingEngine else { return nil }
        pendingEngine = nil
        return apply(.engine(engine))
    }

    package func setCharset(_ charset: String) -> Task<Void, Never>? {
        guard charset != self.charset else { return nil }
        return apply(.charset(charset))
    }

    package func setCollation(_ collation: String) -> Task<Void, Never>? {
        guard collation != status?.collation else { return nil }
        return apply(.collation(collation))
    }

    /// Return in the Comment field.
    package func commitComment() -> Task<Void, Never>? {
        guard comment != status?.comment else { return nil }
        return apply(.comment(comment))
    }

    /// Return in the Auto Increment field. Text that isn't a whole number goes back to the table's value.
    package func commitAutoIncrement() -> Task<Void, Never>? {
        guard let value = TableOption.autoIncrement(from: autoIncrementText) else {
            autoIncrementText = status?.autoIncrement.map { String($0) } ?? ""
            return nil
        }
        guard value != status?.autoIncrement else { return nil }
        return apply(.autoIncrement(value))
    }

    /// Reset Auto Increment: asks for 1, and the server moves it past the highest value in use.
    package func resetAutoIncrement() -> Task<Void, Never>? {
        guard canResetAutoIncrement else { return nil }
        return apply(.autoIncrement(1))
    }

    private func apply(_ option: TableOption) -> Task<Void, Never>? {
        guard canEdit, let target else { return nil }
        isChanging = true
        editError = nil
        let sql = option.sql(table: target.object.name, database: target.database)
        return Task {
            defer { isChanging = false }
            do {
                _ = try await target.client.run(sql)
            } catch {
                editError = DatabaseError.from(error)
            }
            await reload(target)
        }
    }
}
