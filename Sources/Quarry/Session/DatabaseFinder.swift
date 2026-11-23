import Foundation
import Observation
import QuarryKit

/// The Go to Database sheet's state (S-020): a search and the databases that
/// match it. The first match is selected as people type, so Return opens it;
/// ↑ and ↓ move the selection without leaving the search field.
@Observable
final class DatabaseFinder: Identifiable {
    let id = UUID()
    let databases: [String]
    /// The window's database, marked in the list.
    let current: String?

    var search = "" {
        didSet { if search != oldValue { refresh(keepSelection: false) } }
    }
    var selection: String?
    private(set) var matches: [DatabaseMatch] = []

    init(databases: [String], current: String?) {
        self.databases = databases
        self.current = current
        refresh(keepSelection: false)
    }

    var canOpen: Bool { selection.map { name in matches.contains { $0.name == name } } ?? false }

    /// Moves the selection by `offset` rows, staying inside the list.
    func moveSelection(by offset: Int) {
        guard !matches.isEmpty else { return }
        let index = selection.flatMap { name in matches.firstIndex { $0.name == name } } ?? -offset.signum()
        let next = min(max(index + offset, 0), matches.count - 1)
        selection = matches[next].name
    }

    private func refresh(keepSelection: Bool) {
        matches = DatabaseMatcher.matches(search, in: databases)
        if !keepSelection || !canOpen { selection = matches.first?.name }
    }
}
