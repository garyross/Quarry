import Foundation
import QuarryKit
import SwiftData

/// A query run in the Query view (S-033). History belongs to a server and
/// user, as favorite databases do, so every connection to them shares it and
/// it survives a relaunch. `QueryHistory` keeps it short and free of copies.
@Model
final class QueryHistoryEntry {
    var uid: UUID = UUID()
    /// `FavoriteDatabase.serverKey(for:)`.
    var serverKey: String = ""
    var text: String = ""
    /// The database selected when it ran, if any.
    var database: String = ""
    var ranAt: Date = Date.now

    init(text: String, serverKey: String, database: String?) {
        self.text = text
        self.serverKey = serverKey
        self.database = database ?? ""
    }
}

extension AppModel {
    /// Settings > General: Keep the last N queries (1–100, default 20).
    static let historyLimitKey = "query.historyLimit"

    static var historyLimit: Int {
        let stored = UserDefaults.standard.integer(forKey: historyLimitKey)
        return stored > 0 ? QueryHistory.clampedLimit(stored) : QueryHistory.defaultLimit
    }

    /// The history of one server and user, newest first.
    func history(for serverKey: String?) -> [QueryHistoryEntry] {
        guard let serverKey else { return [] }
        return queryHistory.filter { $0.serverKey == serverKey }
    }

    /// Records a run on top; an earlier copy moves up, and the oldest past the limit go.
    func addHistory(_ text: String, serverKey: String, database: String?) {
        let existing = history(for: serverKey)
        let kept = Set(QueryHistory.adding(text, to: existing.map(\.text), limit: Self.historyLimit))
        if let same = existing.first(where: { $0.text == text }) {
            same.ranAt = .now
            same.database = database ?? ""
        } else {
            context.insert(QueryHistoryEntry(text: text, serverKey: serverKey, database: database))
        }
        for entry in existing where !kept.contains(entry.text) { context.delete(entry) }
        try? context.save()
        reloadHistory()
    }

    /// Clear History…: every entry for the server and user.
    func clearHistory(for serverKey: String) {
        for entry in history(for: serverKey) { context.delete(entry) }
        try? context.save()
        reloadHistory()
    }

    func reloadHistory() {
        let descriptor = FetchDescriptor<QueryHistoryEntry>(sortBy: [SortDescriptor(\.ranAt, order: .reverse)])
        queryHistory = (try? context.fetch(descriptor)) ?? []
    }
}
