import Foundation
import QuarryKit
import QuarryControllers

/// Table > Maintenance (S-029): Check, Repair, Analyze, Optimize, Flush and
/// Checksum on the tables selected in the sidebar, with the result in an alert.
/// A SQLite file has Check and Analyze (S-072); a file opened read only, Check.
extension Session {
    /// The objects an operation runs on: the selection's tables, and its views for Check.
    func tableOperationTargets(_ operation: TableOperation, _ ids: Set<String>? = nil) -> [DBObject] {
        objectActions(ids).targets.filter { $0.kind == .table || operation.worksOnViews(engine) }
    }

    /// Whether the operation runs on this window's engine and file.
    func tableOperationWorks(_ operation: TableOperation) -> Bool {
        operation.works(on: engine) && !(isReadOnly && operation.writesToFile)
    }

    /// The menu title, or nil when the operation can't run now.
    func tableOperationTitle(_ operation: TableOperation, _ ids: Set<String>? = nil) -> String? {
        guard runningTableOperation == nil, tableOperationWorks(operation) else { return nil }
        let targets = tableOperationTargets(operation, ids)
        guard !targets.isEmpty else { return nil }
        let views = targets.filter { $0.kind == .view }.count
        return operation.menuTitle(tables: targets.count - views, views: views)
    }

    /// Runs one statement for every target; the alert lists each one's result.
    /// The returned task ends when the result is set (self-test).
    @discardableResult
    func runTableOperation(_ operation: TableOperation, _ ids: Set<String>? = nil) -> Task<Void, Never>? {
        let targets = tableOperationTargets(operation, ids).map(\.name)
        guard !targets.isEmpty, tableOperationWorks(operation), runningTableOperation == nil, let client, let database else { return nil }
        runningTableOperation = operation
        return Task {
            defer { runningTableOperation = nil }
            do {
                let results = try await client.run(operation, on: targets, in: database)
                alert = .notice(title: operation.alertTitle(results), message: operation.alertMessage(results))
            } catch {
                let what = targets.count == 1 ? "\u{201C}\(targets[0])\u{201D}" : "\(targets.count) tables"
                alert = .failure("Couldn’t \(operation.lowercased) \(what)", error)
            }
        }
    }
}
