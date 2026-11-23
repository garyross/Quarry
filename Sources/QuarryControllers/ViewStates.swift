import Foundation
import QuarryKit

/// Columns and rows for a `DataGrid`. A new `revision` makes the grid reload.
package struct GridData: Equatable {
    package struct Column: Equatable {
        /// Unique within the grid ("c0", "c1"…): query results can repeat names.
        package var id: String
        package var title: String
        /// The server column to sort by, or nil when the grid cannot sort on it.
        package var sortKey: String?
        package var isNumeric = false
        /// A BIT column's width: its cells show as bits ("00000101").
        package var bitWidth: Int?
        /// The field starts a foreign key: its cells show an arrow to the row they point at (S-017).
        package var isLinked = false
        /// Hover help for the header and cells: why a query result column is read-only (S-035).
        package var help: String?
        /// A SQLite column's type affinity: a cell stored with another type says so on hover (S-069).
        package var affinity: SQLiteAffinity?

        package init(id: String, title: String, sortKey: String? = nil, isNumeric: Bool = false, bitWidth: Int? = nil,
                     isLinked: Bool = false, help: String? = nil, affinity: SQLiteAffinity? = nil) {
            self.id = id
            self.title = title
            self.sortKey = sortKey
            self.isNumeric = isNumeric
            self.bitWidth = bitWidth
            self.isLinked = isLinked
            self.help = help
            self.affinity = affinity
        }
    }

    package var columns: [Column] = []
    package var rows: [[CellValue]] = []
    package var revision = UUID()

    package static let empty = GridData()

    package static func == (lhs: GridData, rhs: GridData) -> Bool { lhs.revision == rhs.revision }

    package init(columns: [Column] = [], rows: [[CellValue]] = []) {
        self.columns = columns
        self.rows = rows
    }

    /// A query or page result as a grid. `sortable` lets headers sort on the server.
    package init(_ result: StatementResult, sortable: Bool = false) {
        columns = result.columns.enumerated().map { index, column in
            Column(id: "c\(index)", title: column.name, sortKey: sortable ? column.name : nil, isNumeric: column.isNumeric,
                   bitWidth: column.bitWidth)
        }
        rows = result.rows
    }

    /// Picks named columns from a schema result (SHOW INDEX, SHOW TRIGGERS), in this order.
    package init(_ result: StatementResult, picking names: [(server: String, title: String)]) {
        let indexes = names.map { name in
            result.columns.firstIndex { $0.name.caseInsensitiveCompare(name.server) == .orderedSame }
        }
        columns = names.enumerated().map { Column(id: "c\($0.offset)", title: $0.element.title) }
        rows = result.rows.map { row in indexes.map { $0.map { row[$0] } ?? .null } }
    }
}

/// Loading state shared by the views: a spinner shows only after a delay.
package struct LoadState: Equatable {
    package var isLoading = false
    package var error: DatabaseError?
    /// "database/object" the data belongs to, so switching back does not reload.
    package var loadedFor: String?

    /// Wait this long before showing a spinner or dimming: shorter loads show nothing.
    /// `Motion.loadingDelay`, the design token, is this value.
    package static let spinnerDelay: Duration = .milliseconds(500)

    /// Rows per page in Content when Settings > General has none.
    package static let defaultPageSize = 1000

    package init(isLoading: Bool = false, error: DatabaseError? = nil, loadedFor: String? = nil) {
        self.isLoading = isLoading
        self.error = error
        self.loadedFor = loadedFor
    }
}

package struct GridState: Equatable {
    package var grid = GridData.empty
    package var load = LoadState()

    package init(grid: GridData = .empty, load: LoadState = LoadState()) {
        self.grid = grid
        self.load = load
    }
}

/// Runs `work`; `set(true)` only if it takes longer than `LoadState.spinnerDelay`.
package func withLoading(_ set: @escaping (Bool) -> Void, _ work: () async -> Void) async {
    let spinner = Task {
        try? await Task.sleep(for: LoadState.spinnerDelay)
        if !Task.isCancelled { set(true) }
    }
    await work()
    spinner.cancel()
    set(false)
}

/// Grids for schema results, shared by the controllers.
extension GridData {
    /// SHOW INDEX columns in Structure's Indexes grid.
    package static let indexColumns: [(server: String, title: String)] = [
        ("Key_name", "Name"), ("Column_name", "Field"), ("Seq_in_index", "Seq"), ("Non_unique", "Non-unique"),
        ("Index_type", "Type"), ("Cardinality", "Cardinality"), ("Sub_part", "Sub Part"), ("Collation", "Collation"),
        ("Comment", "Comment"),
    ]

    /// SHOW TRIGGERS columns in the Triggers grid.
    package static let triggerColumns: [(server: String, title: String)] = [
        ("Trigger", "Trigger"), ("Event", "Event"), ("Timing", "Timing"), ("Statement", "Statement"),
        ("Definer", "Definer"), ("Created", "Created"), ("sql_mode", "SQL Mode"),
    ]

    /// The Foreign Keys grid.
    package static func foreignKeys(_ keys: [ForeignKeyInfo], database: String) -> GridData {
        let titles = ["Name", "Fields", "References", "Referenced Fields", "On Update", "On Delete"]
        let columns = titles.enumerated().map { GridData.Column(id: "c\($0.offset)", title: $0.element) }
        let rows: [[CellValue]] = keys.map { key in
            let table = key.referencedDatabase == database ? key.referencedTable : "\(key.referencedDatabase).\(key.referencedTable)"
            return [.text(key.name), .text(key.columns), .text(table), .text(key.referencedColumns),
                    .text(key.onUpdate), .text(key.onDelete)]
        }
        return GridData(columns: columns, rows: rows)
    }
}
