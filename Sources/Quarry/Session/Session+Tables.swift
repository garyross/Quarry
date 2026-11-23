import Foundation
import QuarryKit
import QuarryControllers

/// Rename, duplicate, empty and delete tables and views (S-022).
extension Session {
    /// What the sidebar's objects can do now: the context menu's rows when
    /// given, else the selection, else the shown object (`ObjectActions`, FIXLOG).
    func objectActions(_ ids: Set<String>? = nil) -> ObjectActions {
        ObjectActions(isConnected: phase == .connected, database: database, isReadOnly: isReadOnly, engine: engine,
                      objects: objects, clicked: ids, selection: sidebarSelection, shown: selectedObjectID)
    }

    // MARK: Rename

    /// Rename Table… (⌃⌘R): the name becomes a field in the sidebar.
    func requestRenameTable(_ ids: Set<String>? = nil) {
        guard let object = objectActions(ids).rename else { return }
        renameText = object.name
        renamingObjectID = object.id
    }

    func cancelRename() { renamingObjectID = nil }

    /// Return or clicking away: RENAME TABLE, then the object stays selected
    /// under its new name. A taken or invalid name keeps the old one and says why.
    @discardableResult
    func commitRename() -> Task<Void, Never>? {
        guard let id = renamingObjectID, let object = objects.first(where: { $0.id == id }),
              let client, let database else { renamingObjectID = nil; return nil }
        renamingObjectID = nil
        let name = renameText
        guard name != object.name, !name.isEmpty else { return nil }
        let others = objects.filter { ($0.kind == .table || $0.kind == .view) && $0.id != id }.map(\.name)
        let noun = object.kind == .view ? "view" : "table"
        // A change of case alone is a rename too, so the object's own name is not "taken".
        if let problem = SchemaName.problem(with: name, noun: noun, existing: others, taken: "A table or view") {
            alert = .notice(title: "Couldn’t rename \u{201C}\(object.name)\u{201D}", message: problem)
            return nil
        }
        return Task {
            do {
                try await client.rename(table: object.name, to: name, in: database)
            } catch {
                alert = .failure("Couldn’t rename \u{201C}\(object.name)\u{201D}", error)
                return
            }
            if let details = connectedDetails { model?.renameTable(object.name, to: name, in: database, on: details) }
            let wasShown = selectedObjectID == id
            await reloadObjects(database)
            if wasShown { await show(DBObject(name: name, kind: object.kind).id) }
        }
    }

    // MARK: Duplicate

    /// Duplicate Table… (⌃⌘D): opens the sheet with "orders_copy" filled in.
    func requestDuplicateTable(_ ids: Set<String>? = nil) {
        guard let object = objectActions(ids).duplicate, let database, tableDuplicator == nil else { return }
        let names = objects.filter { $0.kind == .table || $0.kind == .view }.map(\.name)
        tableDuplicator = TableDuplicator(database: database, source: object.name, existing: names)
    }

    /// Duplicate in the sheet: copies the table, then selects the copy.
    /// The returned task ends when the copy is shown (self-test).
    @discardableResult
    func runDuplicateTable() -> Task<Void, Never>? {
        guard let client, let duplicator = tableDuplicator, duplicator.canRun else { return nil }
        return Task {
            guard await duplicator.run(client) else { return }
            tableDuplicator = nil
            guard database == duplicator.database else { return }
            await reloadObjects(duplicator.database)
            await show(DBObject(name: duplicator.name, kind: .table).id)
        }
    }

    // MARK: Empty and Delete

    /// Empty Table… (⌃⌘⌫): asks first, naming the table or the count.
    func requestEmptyTables(_ ids: Set<String>? = nil) {
        let targets = objectActions(ids).empty
        guard !targets.isEmpty else { return }
        alert = .tableEdit(PendingTableEdit(action: .empty, objects: targets))
    }

    /// Delete Table… (⌥⌘⌫, or ⌫ in the sidebar): asks first.
    func requestDeleteTables(_ ids: Set<String>? = nil) {
        let targets = objectActions(ids).delete
        guard !targets.isEmpty else { return }
        alert = .tableEdit(PendingTableEdit(action: .delete, objects: targets))
    }

    /// Empty or Delete in the alert. The returned task ends when the sidebar
    /// and the shown view have caught up (self-test).
    @discardableResult
    func confirmTableEdit() -> Task<Void, Never>? {
        guard let client, let database, let edit = alert?.tableEdit else { return nil }
        alert = nil
        return Task {
            let problems: [TableEditProblem]
            switch edit.action {
            case .empty:
                problems = await client.empty(tables: edit.objects.map(\.name), in: database,
                                              ignoringForeignKeys: edit.ignoreForeignKeys)
            case .delete:
                problems = await client.delete(edit.objects, in: database, ignoringForeignKeys: edit.ignoreForeignKeys)
            }
            if !problems.isEmpty {
                let verb = edit.action == .empty ? "empty" : "delete"
                var message = problems.map { "\u{201C}\($0.name)\u{201D}: \($0.message)" }.joined(separator: "\n")
                if !edit.ignoreForeignKeys, problems.contains(where: { TableEdit.isForeignKeyError($0.message) }) {
                    message += "\n\nTurn on Ignore foreign keys to force it."
                }
                alert = .notice(
                    title: problems.count == 1 && edit.objects.count == 1
                        ? "Couldn’t \(verb) \u{201C}\(edit.objects[0].name)\u{201D}" : "Couldn’t \(verb) every \(verb == "empty" ? "table" : "item")",
                    message: message)
            }
            switch edit.action {
            case .empty:
                if let shown = selectedObjectID, edit.objects.contains(where: { $0.id == shown }) {
                    reloadCurrentView(force: true)
                    await currentLoad?.value
                }
            case .delete:
                if let details = connectedDetails {
                    for object in edit.objects { model?.forgetTable(object.name, in: database, on: details) }
                }
                await reloadObjects(database)
                if let shown = selectedObjectID, !objects.contains(where: { $0.id == shown }) { selectedObjectID = nil }
                sidebarSelection = sidebarSelection.filter { id in objects.contains { $0.id == id } }
            }
        }
    }

    // MARK: Helpers

    private func reloadObjects(_ database: String) async {
        guard let client, self.database == database else { return }
        do {
            try await loadObjects(client, database)
        } catch {
            browseError = DatabaseError.from(error)
        }
    }

    /// Selects an object and shows it on the current view, clearing a filter that hides it.
    private func show(_ id: String) async {
        guard objects.contains(where: { $0.id == id }) else { return }
        if !(objects.first { $0.id == id }?.matches(objectFilter) ?? true) { objectFilter = "" }
        isNavigating = true
        selectedObjectID = id
        isNavigating = false
        reloadCurrentView(force: true)
        await currentLoad?.value
    }
}
