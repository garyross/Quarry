import Foundation
import QuarryKit
import SwiftData

/// A query kept by name (S-034). Saved queries belong to the Mac, not to a
/// server, as Sequel Pro's global favorites did, so one written for a staging
/// server is there for production too.
@Model
final class SavedQuery {
    var uid: UUID = UUID()
    var name: String = ""
    var text: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(name: String, text: String) {
        self.name = name
        self.text = text
    }

    var item: SavedQueryFile.Item { .init(name: name, query: text) }
}

extension AppModel {
    func savedQuery(named name: String) -> SavedQuery? {
        savedQueries.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    /// Save Query…: a new saved query, or the one with this name gets the new text.
    @discardableResult
    func saveQuery(_ text: String, named name: String) -> SavedQuery {
        if let found = savedQuery(named: name) {
            found.text = text
            found.updatedAt = .now
            commitSavedQueries()
            return found
        }
        let saved = SavedQuery(name: name, text: text)
        context.insert(saved)
        commitSavedQueries()
        return saved
    }

    /// The Saved Queries window's +: an empty query named "New Query", "New Query 2"…
    func addSavedQuery() -> SavedQuery {
        let saved = SavedQuery(name: SavedQueryFile.uniqueName("New Query", among: savedQueries.map(\.name)), text: "")
        context.insert(saved)
        commitSavedQueries()
        return saved
    }

    func duplicateSavedQuery(_ uid: UUID) -> SavedQuery? {
        guard let source = savedQueries.first(where: { $0.uid == uid }) else { return nil }
        let copy = SavedQuery(name: SavedQueryFile.copyName(source.name, among: savedQueries.map(\.name)), text: source.text)
        context.insert(copy)
        commitSavedQueries()
        return copy
    }

    func deleteSavedQueries(_ uids: Set<UUID>) {
        for saved in savedQueries where uids.contains(saved.uid) { context.delete(saved) }
        commitSavedQueries()
    }

    /// Import…: adds the items, skipping exact copies and numbering names in use.
    /// `replacing` deletes every saved query first (Import by Replacing…). Returns the ones added.
    @discardableResult
    func importSavedQueries(_ items: [SavedQueryFile.Item], replacing: Bool) -> [SavedQuery] {
        if replacing { for saved in savedQueries { context.delete(saved) } }
        let existing = replacing ? [] : savedQueries.map(\.item)
        let added = SavedQueryFile.merging(items, into: existing).map { SavedQuery(name: $0.name, text: $0.query) }
        for saved in added { context.insert(saved) }
        commitSavedQueries()
        return added
    }

    /// Edits in the Saved Queries window: kept, and the menus resorted.
    func commitSavedQueries() {
        try? context.save()
        reloadSavedQueries()
    }

    func reloadSavedQueries() {
        let descriptor = FetchDescriptor<SavedQuery>(sortBy: [SortDescriptor(\.createdAt)])
        let all = (try? context.fetch(descriptor)) ?? []
        savedQueries = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
