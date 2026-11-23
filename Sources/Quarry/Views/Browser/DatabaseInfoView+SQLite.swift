import QuarryKit
import QuarryControllers
import SwiftUI

/// S-072: the top of the Database Information panel for a SQLite file.
struct SQLiteOverview: View {
    let file: SQLiteFileInfo

    var body: some View {
        LabeledContent("Contains") {
            Text(file.countsLine)
                .help("\(file.indexesLine) besides the primary keys")
        }
        LabeledContent("Size") {
            Text(ByteCount.format(file.fileBytes))
                .help("The file on disk. A -wal file beside it is not counted.")
        }
        LabeledContent("Pages") {
            Text(file.pagesLine)
                .help("Free pages are allocated but unused: \(ByteCount.format(file.freeBytes)). Vacuum gives them back.")
        }
        LabeledContent("Journal Mode", value: file.journalTitle)
        LabeledContent("Encoding", value: file.encoding)
        LabeledContent("Foreign Keys") {
            Text(file.foreignKeys ? "On" : "Off")
                .help(file.foreignKeys ? "SQLite checks foreign keys as rows change." : "SQLite doesn’t check foreign keys on this connection.")
        }
        LabeledContent("SQLite", value: file.version)
        if file.isReadOnly {
            LabeledContent("Access", value: "Read Only")
        }
    }
}

/// What Integrity Check, Foreign Key Check, Analyze, Optimize and Vacuum found.
struct SQLiteToolResults: View {
    @Environment(Session.self) private var session
    let tool: DatabaseInfo.Tool

    var body: some View {
        let info = session.databaseInfo
        if info.running != tool {
            Section(tool.title.replacingOccurrences(of: "…", with: "")) {
                switch tool {
                case .integrity, .foreignKeys:
                    if info.fileChecks.isEmpty {
                        StatusRow(severity: .ok, title: info.wasCancelled ? "Stopped" : "No problems found.",
                                  detail: info.wasCancelled ? "Stopped before the rest." : okDetail(info))
                    } else {
                        ForEach(info.fileChecks) { check in
                            StatusRow(severity: check.severity, title: check.table, detail: check.message)
                        }
                    }
                default:
                    if let result = info.fileResult {
                        StatusRow(severity: .ok, title: result)
                    }
                }
            }
        }
    }

    private func okDetail(_ info: DatabaseInfo) -> String {
        let tables = StatementResult.formatCount(info.fileInfo?.tables.count ?? 0, "table")
        return tool == .integrity ? "Checked every page, row and index of \(tables)."
            : "Every row in \(tables) refers to a row that exists."
    }
}
