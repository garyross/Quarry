import Foundation
import QuarryKit
import QuarryControllers

/// Duplicate, rename, change the character set of, or delete the current database (S-019).
extension Session {
    /// The current database, when it is one people may change (not a system database).
    var editableDatabase: String? {
        guard phase == .connected, !isSQLite, let database, !DatabaseTransfer.isSystem(database) else { return nil }
        return database
    }

    /// The current database, when it can be copied: mysql and sys can, the
    /// in-memory information_schema and performance_schema cannot.
    var duplicableDatabase: String? {
        guard phase == .connected, !isSQLite, let database, let client, !client.dialect.isInMemory(database) else { return nil }
        return database
    }

    /// Database > Duplicate Database… (⌥⇧⌘N), Rename Database… (⌥⇧⌘R), Change Character Set… (⌥⇧⌘C).
    func requestDatabaseEditor(_ mode: DatabaseEditor.Mode) {
        guard let client, databaseEditor == nil, newDatabase == nil else { return }
        guard let source = mode == .duplicate ? duplicableDatabase : editableDatabase else { return }
        let editor = DatabaseEditor(mode: mode, source: source, existing: databases)
        databaseEditor = editor
        if mode == .alter { Task { await editor.load(client) } }
    }

    /// Duplicate, Rename or Change in the sheet. On success the new (or
    /// renamed) database is selected; problems keep the sheet open with a list.
    /// The returned task ends when the new database's objects have loaded (self-test).
    @discardableResult
    func runDatabaseEditor() -> Task<Void, Never>? {
        guard let client, let editor = databaseEditor, editor.canRun else { return nil }
        return Task {
            guard await editor.run(client) else { return }
            if editor.problems.isEmpty { databaseEditor = nil }
            switch editor.mode {
            case .alter:
                databaseInfo.reset()
                loadDatabaseInfo(force: true)
            case .rename:
                if let details = connectedDetails { model?.renameDatabase(editor.source, to: editor.name, on: details) }
                await loadDatabases(select: editor.name)
            case .duplicate:
                await loadDatabases(select: editor.name)
            }
        }
    }

    /// Database > Delete Database… (⇧⌘⌫): asks first, naming the database.
    func requestDeleteDatabase() {
        guard let database = editableDatabase else { return }
        alert = .deleteDatabase(database)
    }

    /// Delete in the alert: DROP DATABASE, then "Choose a Database".
    /// Favorites and saved filters on it go too.
    @discardableResult
    func confirmDeleteDatabase() -> Task<Void, Never>? {
        guard let client, let name = alert?.databaseToDelete else { return nil }
        alert = nil
        return Task {
            do {
                try await client.drop(database: name)
            } catch {
                alert = .failure("Couldn’t delete the database", error)
                return
            }
            if let details = connectedDetails { model?.forgetDatabase(name, on: details) }
            if database == name { database = nil }
            await loadDatabases(select: nil)
        }
    }
}

/// Go to Database (S-020): jump to a database by typing part of its name.
extension Session {
    /// Database > Go to Database… (⇧⌘D).
    func requestGoToDatabase() {
        guard phase == .connected, goToDatabase == nil, newDatabase == nil, databaseEditor == nil else { return }
        goToDatabase = DatabaseFinder(databases: databases, current: database)
    }

    /// Open in the sheet, Return, or a double-click: switch to the selected database.
    func openFoundDatabase() {
        guard let finder = goToDatabase, finder.canOpen, let name = finder.selection else { return }
        goToDatabase = nil
        database = name
    }
}
