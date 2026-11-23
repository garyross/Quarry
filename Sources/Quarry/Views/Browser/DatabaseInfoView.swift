import AppKit
import QuarryKit
import QuarryControllers
import SwiftUI

/// The Database Information panel (⌥⌘I): the database at a glance, four
/// tool buttons, and the last tool's results.
struct DatabaseInfoView: View {
    @Environment(Session.self) private var session

    var body: some View {
        let info = session.databaseInfo
        Form {
            overview(info)
            Section("Tools") {
                tools(info)
                if info.running != nil {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text(info.progress)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Cancel") { info.cancel() }
                            .help("Stop after the current table")
                    }
                }
            }
            if let shown = info.shown {
                ToolResults(tool: shown)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(repairTitle(info), isPresented: Bindable(info).confirmingRepair) {
            Button("Repair", role: .destructive) { session.confirmRepair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Back up the database first. MyISAM and Aria tables are repaired with REPAIR TABLE; "
                 + "InnoDB tables are rebuilt with ALTER TABLE … FORCE. Each table is locked while it is repaired.")
        }
        .confirmationDialog("Vacuum \u{201C}\(info.fileInfo?.fileName ?? "")\u{201D}?", isPresented: Bindable(info).confirmingVacuum) {
            Button("Vacuum") { session.confirmVacuum() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(info.fileInfo?.vacuumMessage ?? "")
        }
    }

    private func repairTitle(_ info: DatabaseInfo) -> String {
        let count = info.tablesToRepair.count
        return count == 1 ? "Repair \(info.tablesToRepair[0].table)?" : "Repair \(count) Tables?"
    }

    @ViewBuilder
    private func overview(_ info: DatabaseInfo) -> some View {
        Section {
            if let file = info.fileInfo {
                SQLiteOverview(file: file)
            } else if let overview = info.overview {
                LabeledContent("Contains", value: overview.countsLine)
                LabeledContent("Size") {
                    Text("\(ByteCount.format(overview.dataBytes + overview.indexBytes))")
                        .help("Data \(ByteCount.format(overview.dataBytes)), indexes \(ByteCount.format(overview.indexBytes))")
                }
                LabeledContent("Rows") {
                    Text("about \(overview.rows.formatted())")
                        .help("The server's estimate. InnoDB counts are approximate.")
                }
                LabeledContent("Character Set", value: overview.charset)
                LabeledContent("Collation") {
                    Text(overview.collation).textSelection(.enabled)
                }
                if !overview.engines.isEmpty {
                    LabeledContent("Engines", value: overview.engines.map { "\($0.name) \($0.count)" }.joined(separator: ", "))
                }
                LabeledContent("Connection") {
                    Text(session.encryption.map { "SSL, \($0.version)" } ?? "Not encrypted")
                        .help(session.encryption?.description
                              ?? "Turn on Use SSL in the connection's details to encrypt it.")
                }
            } else if let error = info.overviewError {
                ErrorMessage(error: error)
            } else {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
            }
        } header: {
            Text(info.fileInfo?.fileName ?? session.database ?? "")
                .font(.headline)
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }

    private func tools(_ info: DatabaseInfo) -> some View {
        let tools = DatabaseInfo.Tool.tools(for: info.engine)
        return Grid(horizontalSpacing: Space.sm, verticalSpacing: Space.sm) {
            ForEach(Array(stride(from: 0, to: tools.count, by: 2)), id: \.self) { start in
                GridRow {
                    ForEach(tools[start..<min(start + 2, tools.count)]) { tile($0, info) }
                }
            }
        }
        .padding(.vertical, Space.xs)
    }

    private func tile(_ tool: DatabaseInfo.Tool, _ info: DatabaseInfo) -> some View {
        Button { session.runTool(tool) } label: {
            Label(tool.title, systemImage: tool.symbol)
        }
        .buttonStyle(TileButtonStyle(isRisky: tool.isRisky))
        .disabled(!info.canRun(tool))
        .help(tileHelp(tool, info))
        .accessibilityHint(tool.help(info.engine))
    }

    private func tileHelp(_ tool: DatabaseInfo.Tool, _ info: DatabaseInfo) -> String {
        if tool == .repair && info.tablesToRepair.isEmpty { return "Run Check Tables first. Repair works on the tables it flags." }
        if tool.writesToFile && info.fileInfo?.isReadOnly == true {
            return "The file is open read only. \(tool.help(.sqlite))"
        }
        return tool.help(info.engine)
    }
}

/// What the last tool found.
private struct ToolResults: View {
    @Environment(Session.self) private var session
    let tool: DatabaseInfo.Tool

    var body: some View {
        let info = session.databaseInfo
        if let error = info.toolError {
            Section(tool.title.replacingOccurrences(of: "…", with: "")) {
                ErrorMessage(error: error)
            }
        } else {
            switch tool {
            case .check: checkResults(info.checks, verb: "checked", info: info)
            case .repair: checkResults(info.repairs, verb: "repaired", info: info)
            case .collations: collationResults(info)
            case .health: healthResults(info)
            case .integrity, .foreignKeys, .analyze, .optimize, .vacuum: SQLiteToolResults(tool: tool)
            }
        }
    }

    @ViewBuilder
    private func checkResults(_ results: [TableCheck], verb: String, info: DatabaseInfo) -> some View {
        let problems = results.filter { $0.severity > .ok }
        Section {
            if info.running == tool, results.isEmpty {
                EmptyView()
            } else if problems.isEmpty {
                StatusRow(severity: .ok, title: "\(verb == "checked" ? "All" : "Every") \(StatementResult.formatCount(results.count, "table")) \(verb == "checked" ? "OK" : "repaired")",
                          detail: info.wasCancelled ? "Stopped before the rest." : nil)
            } else {
                ForEach(problems) { result in
                    StatusRow(severity: result.severity, title: result.table, detail: result.message)
                }
                if verb == "checked" {
                    Text("Repair Tables fixes these. Back up the database first.")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(verb == "checked" ? "Check Tables" : "Repair Tables")
        } footer: {
            if !problems.isEmpty || info.wasCancelled {
                Text("\(StatementResult.formatCount(results.count, "table")) \(verb)\(info.wasCancelled ? ", then stopped" : ""): "
                     + "\(results.count - problems.count) OK, \(problems.count) with problems.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func collationResults(_ info: DatabaseInfo) -> some View {
        if let report = info.collations {
            Section("Collations") {
                LabeledContent("Database Default") {
                    Text(report.defaultCollation)
                        .foregroundStyle(Charsets.isUTF8MB3(report.defaultCharset) ? StatusStyle.warning : .primary)
                }
                ForEach(report.uses) { use in
                    StatusRow(severity: use.severity, title: use.collation,
                              detail: "\(StatementResult.formatCount(use.columns, "column")) in \(TableList.text(use.tables))")
                }
                if report.uses.isEmpty {
                    Text("No text columns.").foregroundStyle(.secondary)
                }
            }
            if let sql = report.conversionSQL {
                Section {
                    Text("utf8mb3 can't store emoji or some Chinese, Japanese and Korean characters. "
                         + "Converting \(StatementResult.formatCount(report.tablesToConvert.count, "table")) to utf8mb4 keeps each collation's sorting rules.")
                        .fixedSize(horizontal: false, vertical: true)
                    SQLActions(sql: sql)
                } header: {
                    Label("utf8mb3 in Use", systemImage: StatusStyle.warningSymbol)
                }
            }
        }
    }

    @ViewBuilder
    private func healthResults(_ info: DatabaseInfo) -> some View {
        if !info.findings.isEmpty {
            Section("Health Check") {
                ForEach(info.findings) { finding in
                    StatusRow(severity: finding.severity, title: finding.title, detail: finding.detail) {
                        if !finding.tables.isEmpty {
                            Text(TableList.text(finding.tables))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .help(finding.tables.joined(separator: ", "))
                        }
                        if let sql = finding.sql {
                            SQLActions(sql: sql)
                                .padding(.top, Space.xs)
                        }
                    }
                    .padding(.vertical, Space.xs)
                }
            }
        }
    }
}

/// An icon for the severity, a title, and an optional detail line.
struct StatusRow<Extra: View>: View {
    let severity: Severity
    let title: String
    var detail: String?
    /// Table names and fix buttons, aligned with the text.
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: SeverityStyle.symbol(severity))
                .foregroundStyle(SeverityStyle.color(severity))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title)
                    .fontWeight(severity > .ok ? .medium : .regular)
                    .textSelection(.enabled)
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                extra
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(SeverityStyle.word(severity)): \(title). \(detail ?? "")")
    }

}

extension StatusRow where Extra == EmptyView {
    init(severity: Severity, title: String, detail: String? = nil) {
        self.init(severity: severity, title: title, detail: detail) { EmptyView() }
    }
}

enum SeverityStyle {
    static func symbol(_ severity: Severity) -> String {
        switch severity {
        case .ok: StatusStyle.successSymbol
        case .info: "info.circle.fill"
        case .warning: StatusStyle.warningSymbol
        case .error: StatusStyle.errorSymbol
        }
    }

    static func color(_ severity: Severity) -> Color {
        switch severity {
        case .ok: StatusStyle.success
        case .info: .secondary
        case .warning: StatusStyle.warning
        case .error: StatusStyle.error
        }
    }

    static func word(_ severity: Severity) -> String {
        switch severity {
        case .ok: "OK"
        case .info: "Note"
        case .warning: "Warning"
        case .error: "Problem"
        }
    }
}

/// Fix statements are never run from here: they go to the Query editor (or
/// the clipboard) for people to read first.
struct SQLActions: View {
    @Environment(Session.self) private var session
    let sql: String

    var body: some View {
        HStack(spacing: Space.sm) {
            Button("Open in Query") { session.openInQuery(sql) }
                .help("Put these statements in the Query editor to review and run (⌘6)")
            Button("Copy SQL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sql, forType: .string)
            }
            .help("Copy the statements to the clipboard")
        }
        .controlSize(.small)
    }
}

enum TableList {
    /// "orders, customers and 3 more"
    static func text(_ tables: [String], showing limit: Int = 3) -> String {
        guard tables.count > limit else { return ListFormatter.localizedString(byJoining: tables) }
        return tables.prefix(limit).joined(separator: ", ") + " and \(tables.count - limit) more"
    }
}
