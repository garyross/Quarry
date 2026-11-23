import Foundation
import QuarryKit
import QuarryControllers

/// Following a foreign key (S-017), and Back and Forward through every
/// database, table and view the window showed (S-038).
extension Session {
    /// Where the window is: a database, maybe an object, a view, and Content's filter, sort and page.
    struct Place: Equatable {
        var database: String
        var objectID: String?
        var view: DetailView
        var content: ContentController.Saved?

        /// Same database and object: a change of view or filter, not a new place.
        func isSameObject(as other: Place) -> Bool {
            database == other.database && objectID == other.objectID
        }
    }

    /// Content's state rides along whenever it belongs to this object, on any view.
    var currentPlace: Place? {
        guard let database else { return nil }
        var place = Place(database: database, objectID: selectedObjectID, view: view)
        if let selectedObjectID, let saved = content.saved, saved.key == "\(database)/\(selectedObjectID)" {
            place.content = saved
        }
        return place
    }

    /// The place being left, as it is now: Content's filter, sort and page
    /// are read before the next table replaces them. Call before the change shows.
    func placeBeingLeft() -> Place? {
        guard var place = shownPlace else { return nil }
        if let objectID = place.objectID, let saved = content.saved, saved.key == "\(place.database)/\(objectID)" {
            place.content = saved
        }
        return place
    }

    /// Records a visit after the database, object or view changed (S-038).
    /// A view change only updates the place, as in Sequel Pro, and a database
    /// with nothing selected yet gives way to the first object opened in it.
    func noteVisit(leaving left: Place?) {
        guard !isNavigating, phase == .connected else { return }
        let now = currentPlace
        shownPlace = now
        guard let left, let now, !left.isSameObject(as: now) else { return }
        if left.objectID == nil, left.database == now.database { return }
        history.visit(leaving: left)
    }

    /// The arrow in a foreign-key cell: the referenced table's Content, filtered
    /// to the cell's value. Back returns. The task ends when the rows show (self-test).
    @discardableResult
    func followLink(row: Int, column: Int) -> Task<Void, Never>? {
        guard let here = currentPlace, let place = linkPlace(row: row, column: column) else { return nil }
        return Task {
            if await go(to: place) { history.visit(leaving: here) }
        }
    }

    /// The referenced table's Content, filtered to the cell's value.
    func linkPlace(row: Int, column: Int) -> Place? {
        guard let database, let link = content.link(row: row, column: column),
              let filter = link.filter(for: content.grid.rows[row][column]) else { return nil }
        let target = link.database.isEmpty ? database : link.database
        let object = DBObject(name: link.table, kind: .table)
        let saved = ContentController.Saved(key: "\(target)/\(object.id)", filter: filter, appliedClause: filter.whereClause(engine: client?.dialect.engine ?? .mysql))
        return Place(database: target, objectID: object.id, view: .content, content: saved)
    }

    /// While the grid has focus, so ⌘↓ still moves the cursor in text fields.
    var canOpenReferencedRow: Bool {
        guard view == .content, content.gridHasFocus, content.selection.count == 1, let row = content.selection.first else { return false }
        return !content.followableLinks(row: row).isEmpty
    }

    /// Table > Open Referenced Row (⌘↓): the selected row's first foreign key.
    @discardableResult
    func openReferencedRow() -> Task<Void, Never>? {
        guard content.selection.count == 1, let row = content.selection.first,
              let column = content.followableLinks(row: row).first else { return nil }
        return followLink(row: row, column: column)
    }

    /// View > Back (⌃⌥←; ⌘[ outside Query).
    @discardableResult
    func goBack() -> Task<Void, Never>? {
        guard let here = currentPlace, let place = history.goBack(from: here) else { return nil }
        return Task {
            if !(await go(to: place)) { history.visit(leaving: here) }
        }
    }

    /// View > Forward (⌃⌥→; ⌘] outside Query).
    @discardableResult
    func goForward() -> Task<Void, Never>? {
        guard let here = currentPlace, let place = history.goForward(from: here) else { return nil }
        return Task {
            if !(await go(to: place)) { history = History() }
        }
    }

    /// Shows a place: its database first, then the object and view with one load.
    /// False, with the reason in Content, when the object is gone.
    func go(to place: Place) async -> Bool {
        guard phase == .connected else { return false }
        defer { shownPlace = currentPlace }
        if database != place.database {
            guard databases.contains(place.database) else {
                content.editError = DatabaseError(message: "There is no database \u{201C}\(place.database)\u{201D}.",
                                                  suggestion: "It may have been renamed or dropped.")
                return false
            }
            isNavigating = true
            database = place.database
            isNavigating = false
            await currentLoad?.value
        }
        guard let objectID = place.objectID else {
            isNavigating = true
            selectedObjectID = nil
            view = place.view
            isNavigating = false
            return true
        }
        // A connection file names a table only (S-055): find it as a view or routine too.
        let name = objectID.split(separator: ":", maxSplits: 1).last.map(String.init)
        guard let object = objects.first(where: { $0.id == objectID }) ?? objects.first(where: { $0.name == name }) else {
            content.editError = DatabaseError(message: "There is no table \u{201C}\(objectID.split(separator: ":").last ?? "")\u{201D} in \(place.database).",
                                              suggestion: "Refresh (⇧⌘R) if it was just created.")
            return false
        }
        if !object.matches(objectFilter) { objectFilter = "" }
        content.pendingRestore = place.content
        isNavigating = true
        selectedObjectID = object.id
        view = place.view.applies(to: object.kind) ? place.view : .info
        isNavigating = false
        reloadCurrentView(force: false)
        await currentLoad?.value
        return true
    }
}
