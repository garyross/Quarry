import Foundation
import Observation
import QuarryKit

/// The Database Information panel: the current database's overview and the
/// maintenance tools. Its own `@Observable`, so the panel redraws without
/// touching the rest of the window (architecture review, 2026-11-18).
@Observable
package final class DatabaseInfo {
    package init() {}

    package enum Tool: String, CaseIterable, Identifiable {
        case check, repair, collations, health
        // S-072: a SQLite file's tools.
        case integrity, foreignKeys, analyze, optimize, vacuum

        package var id: String { rawValue }

        /// The panel's tools for an engine, in the order of its tiles.
        package static func tools(for engine: Engine) -> [Tool] {
            engine == .sqlite ? [.integrity, .foreignKeys, .health, .analyze, .optimize, .vacuum]
                : [.check, .repair, .collations, .health]
        }

        package var title: String {
            switch self {
            case .check: "Check Tables"
            case .repair: "Repair Tables…"
            case .collations: "Find Collations"
            case .health: "Health Check"
            case .integrity: "Integrity Check"
            case .foreignKeys: "Foreign Key Check"
            case .analyze: "Analyze"
            case .optimize: "Optimize"
            case .vacuum: "Vacuum…"
            }
        }

        package var symbol: String {
            switch self {
            case .check: "checkmark.shield"
            case .repair: "wrench.and.screwdriver"
            case .collations: "character.book.closed"
            case .health: "stethoscope"
            case .integrity: "checkmark.shield"
            case .foreignKeys: "link"
            case .analyze: "chart.bar"
            case .optimize: "gauge.with.dots.needle.67percent"
            case .vacuum: "arrow.down.right.and.arrow.up.left"
            }
        }

        package func help(_ engine: Engine) -> String {
            switch self {
            case .check: "Run CHECK TABLE on every table to find corruption"
            case .repair: "Repair the tables Check Tables flagged. Changes data: back up first"
            case .collations: "List the character sets and collations in use, and how to move utf8mb3 to utf8mb4"
            case .health where engine == .sqlite:
                "Look for foreign key errors, free pages, referenced tables with no primary key and foreign keys with no index"
            case .health: "Look for missing primary keys, crash-prone engines, utf8mb3, unused space and auto-increment limits"
            case .integrity: "Run PRAGMA integrity_check: read every page, row and index to find corruption. Only reads"
            case .foreignKeys: "Run PRAGMA foreign_key_check on every table to find rows whose parent row is missing. Only reads"
            case .analyze: "Run ANALYZE: gather fresh statistics so the query planner picks the best index"
            case .optimize: "Run PRAGMA optimize: analyze only the tables whose statistics are stale"
            case .vacuum: "Run VACUUM: rewrite the file to give back its free pages. Asks first"
            }
        }

        /// Changes data, so it asks first and shows a warning mark.
        package var isRisky: Bool { self == .repair }

        /// Writes to a SQLite file, so a file opened read only can't run it.
        package var writesToFile: Bool { [.analyze, .optimize, .vacuum].contains(self) }
    }

    package private(set) var database: String?
    package private(set) var overview: DatabaseOverview?
    /// S-072: a SQLite file's overview, in place of `overview`.
    package private(set) var fileInfo: SQLiteFileInfo?
    /// Integrity Check and Foreign Key Check's problems, and Vacuum/Analyze/Optimize's line.
    package private(set) var fileChecks: [TableCheck] = []
    package private(set) var fileResult: String?
    package private(set) var overviewError: DatabaseError?
    package private(set) var isLoadingOverview = false

    /// The tool running now, and what it is doing: "Checking orders (12 of 59)".
    package private(set) var running: Tool?
    package private(set) var progress = ""
    /// The tool whose results show under the buttons.
    package private(set) var shown: Tool?
    package private(set) var checks: [TableCheck] = []
    package private(set) var repairs: [TableCheck] = []
    package private(set) var collations: CollationReport?
    package private(set) var findings: [Finding] = []
    package private(set) var toolError: DatabaseError?
    /// The tables a run stopped before, when Cancel was pressed.
    package private(set) var wasCancelled = false
    /// Repair asks first; the menu and the button both set this.
    package var confirmingRepair = false
    /// Vacuum asks first too (S-072).
    package var confirmingVacuum = false

    package var engine: Engine { fileInfo != nil ? .sqlite : .mysql }
    package var isLoaded: Bool { overview != nil || fileInfo != nil }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// Tables the last Check Tables flagged.
    package var tablesToRepair: [TableCheck] { checks.filter { $0.severity >= .warning } }

    package func canRun(_ tool: Tool) -> Bool {
        guard running == nil, isLoaded, Tool.tools(for: engine).contains(tool) else { return false }
        if tool.writesToFile, fileInfo?.isReadOnly == true { return false }
        return tool == .repair ? !tablesToRepair.isEmpty : true
    }

    /// Clears everything for another database or a disconnect.
    package func reset() {
        task?.cancel()
        task = nil
        loadTask = nil
        database = nil
        overview = nil
        fileInfo = nil
        fileChecks = []
        fileResult = nil
        confirmingVacuum = false
        overviewError = nil
        isLoadingOverview = false
        running = nil
        progress = ""
        shown = nil
        checks = []
        repairs = []
        collations = nil
        findings = []
        toolError = nil
        wasCancelled = false
        confirmingRepair = false
    }

    /// Loads the overview for `database`, unless it is already showing it.
    /// Loads the overview for `database`, unless it is already showing it.
    /// A second call while one is loading waits for that one, so a tool
    /// started from the menu never sees a missing overview.
    package func load(_ database: String, client: DatabaseClient, force: Bool = false) async {
        if self.database != database { reset() }
        if let loading = loadTask {
            await loading.value
            if !force { return }
        }
        guard force || !isLoaded else { return }
        self.database = database
        let loading = Task {
            isLoadingOverview = true
            defer { isLoadingOverview = false }
            do {
                if client.dialect.engine == .sqlite {
                    let loaded = try await client.sqliteFileInfo()
                    guard self.database == database else { return }
                    fileInfo = loaded
                } else {
                    let loaded = try await client.overview(of: database)
                    guard self.database == database else { return }
                    overview = loaded
                }
                overviewError = nil
            } catch {
                guard self.database == database else { return }
                overviewError = DatabaseError.from(error)
            }
        }
        loadTask = loading
        await loading.value
        if loadTask == loading { loadTask = nil }
    }

    package func cancel() {
        task?.cancel()
    }

    /// Starts `tool`. Repair runs only after `confirmingRepair` was answered,
    /// Vacuum after `confirmingVacuum`.
    package func run(_ tool: Tool, client: DatabaseClient) {
        if let fileInfo, canRun(tool) { return runOnFile(tool, fileInfo, client: client) }
        guard canRun(tool), let overview else { return }
        running = tool
        shown = tool
        toolError = nil
        wasCancelled = false
        progress = ""
        task = Task {
            defer {
                running = nil
                progress = ""
            }
            do {
                switch tool {
                case .check:
                    checks = []
                    let tables = overview.tables
                    for (index, table) in tables.enumerated() {
                        if Task.isCancelled { wasCancelled = true; break }
                        progress = "Checking \(table.name) (\(index + 1) of \(tables.count))"
                        checks.append(try await client.check(table.name, in: overview.name))
                    }
                case .repair:
                    repairs = []
                    let targets = overview.tables.filter { table in tablesToRepair.contains { $0.table == table.name } }
                    for (index, table) in targets.enumerated() {
                        if Task.isCancelled { wasCancelled = true; break }
                        progress = "Repairing \(table.name) (\(index + 1) of \(targets.count))"
                        repairs.append(try await client.repair(table, in: overview.name))
                    }
                    // What was fixed no longer needs repair.
                    for repair in repairs where repair.severity == .ok {
                        if let index = checks.firstIndex(where: { $0.table == repair.table }) {
                            checks[index] = TableCheck(table: repair.table, severity: .ok, message: "Repaired")
                        }
                    }
                case .collations:
                    progress = "Reading the columns of \(overview.name)"
                    collations = try await client.collationReport(for: overview)
                case .health:
                    progress = "Checking \(overview.name)"
                    findings = HealthCheck.run(try await client.healthInput(for: overview))
                case .integrity, .foreignKeys, .analyze, .optimize, .vacuum:
                    break
                }
            } catch {
                toolError = DatabaseError.from(error)
            }
        }
    }

    /// S-072: a SQLite file's tools.
    private func runOnFile(_ tool: Tool, _ info: SQLiteFileInfo, client: DatabaseClient) {
        running = tool
        shown = tool
        toolError = nil
        wasCancelled = false
        fileResult = nil
        progress = ""
        task = Task {
            defer {
                running = nil
                progress = ""
            }
            do {
                switch tool {
                case .integrity:
                    fileChecks = []
                    progress = "Checking \(info.fileName)"
                    fileChecks = try await client.sqliteIntegrityCheck(info)
                case .foreignKeys:
                    fileChecks = []
                    let tables = info.tables
                    fileChecks = try await client.sqliteForeignKeyCheck(tables) { table, index in
                        await MainActor.run { self.progress = "Checking \(table) (\(index + 1) of \(tables.count))" }
                    }
                    .filter { $0.severity > .ok }
                case .health:
                    progress = "Checking \(info.fileName)"
                    findings = SQLiteHealthCheck.run(try await client.sqliteHealthInput(info))
                case .analyze:
                    progress = "Analyzing \(info.fileName)"
                    try await client.sqliteAnalyze()
                    fileResult = "Statistics updated for \(StatementResult.formatCount(info.tables.count, "table"))."
                case .optimize:
                    progress = "Optimizing \(info.fileName)"
                    try await client.sqliteOptimize()
                    fileResult = "Done. SQLite analyzed the tables whose statistics were stale."
                case .vacuum:
                    progress = "Vacuuming \(info.fileName)"
                    try await client.sqliteVacuum()
                    let after = try await client.sqliteFileInfo()
                    fileInfo = after
                    fileResult = SQLiteFileInfo.vacuumResult(info.fileName, before: info.fileBytes, after: after.fileBytes)
                default:
                    break
                }
            } catch is CancellationError {
                wasCancelled = true
            } catch {
                toolError = DatabaseError.from(error)
            }
        }
    }

    /// Awaits the running tool (self-test, snapshots).
    package func waitForTool() async { await task?.value }

    /// Waits until the overview has loaded and no tool runs (`runTool` starts
    /// its work in a Task, so there may be nothing to await yet).
    package func waitUntilIdle() async {
        for _ in 0..<200 {
            if isLoaded || overviewError != nil, running == nil, !isLoadingOverview {
                await task?.value
                if running == nil { return }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
}
