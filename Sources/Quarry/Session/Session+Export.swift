import Foundation
import QuarryKit

/// File > Export… (⇧⌘E), the sidebar's Export… (S-041), and the Query
/// results' Export Results… (S-042).
extension Session {
    var canExport: Bool { phase == .connected && database != nil && client != nil && !objects.isEmpty && exporter == nil }

    /// Opens the Export sheet with every object listed. With `ids` (the row
    /// menu) or several objects selected in the sidebar, only those start checked.
    /// Content's table and the Query results are offered as sources too.
    func requestExport(_ ids: Set<String>? = nil, source: Exporter.Source = .tables, format: Exporter.Format = .sql) {
        guard canExport, let database, let client else { return }
        let chosen = ids ?? (sidebarSelection.count > 1 ? sidebarSelection : [])
        let shown = view == .content ? content.exportSource : nil
        let result = query.resultColumns.isEmpty || query.results.columns.count != query.resultColumns.count
            ? nil : Exporter.QueryRows(columns: query.resultColumns, rows: query.results.rows,
                                       statement: query.resultStatement)
        exporter = Exporter(database: database, objects: objects, chosen: chosen, client: client,
                            content: shown.map { Exporter.ContentRows(database: $0.database, source: $0.source, rows: $0.rows) },
                            result: result, source: source, format: format,
                            host: connectedDetails.map { $0.transport == .tcp ? $0.host : "localhost" } ?? "",
                            connection: connectionName)
    }

    /// The Query results' context menu: the sheet on Query Result as CSV.
    func requestExportResults() {
        requestExport(source: .result, format: .csv)
    }
}
