import AppKit
import QuarryKit
import UniformTypeIdentifiers

/// SQLite files (S-068): File > Open…, File > New SQLite File…, files dropped on
/// the Dock icon or a Connect window, and Locate… for a saved file that moved.
extension Session {
    /// .sqlite, .sqlite3, .db and .db3, and anything the system calls a database.
    static var sqliteFileTypes: [UTType] {
        SQLiteFile.extensions.compactMap { UTType(filenameExtension: $0, conformingTo: .data) } + [.database]
    }

    /// An open panel for one SQLite file.
    static func chooseSQLiteFile(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.allowedContentTypes = sqliteFileTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// The details that open `url`: a saved connection's when one points at it, so its name and color show.
    func sqliteDetails(_ url: URL, model: AppModel?, readOnly: Bool = false) -> (details: ConnectionDetails, saved: UUID?) {
        let path = url.standardizedFileURL.path
        if let saved = model?.savedConnections().first(where: { $0.kind == .sqlite && $0.fields.fileURL?.standardizedFileURL.path == path }) {
            return (saved.details, saved.uid)
        }
        return (ConnectionDetails(transport: .sqlite, file: (path as NSString).abbreviatingWithTildeInPath, readOnly: readOnly), nil)
    }

    /// Opens a SQLite file here when this window shows the Connect page, else in a new tab beside it.
    /// The returned task ends when the file is open (self-test).
    @discardableResult
    func openSQLiteFile(_ url: URL, model: AppModel? = nil) -> Task<Void, Never>? {
        let model = model ?? self.model
        let found = sqliteDetails(url, model: model)
        guard phase == .disconnected else {
            Tabs.open(beside: window, using: openWindowAction) { session, fallback in
                session.form = found.details
                session.selectedSaved = found.saved
                session.connect(model: model ?? fallback)
            }
            return nil
        }
        selectedSaved = found.saved
        selectedFavorite = nil
        form = found.details
        connect(model: model)
        return connectTask
    }

    /// File > Open… with a file that isn't a connection file: SQLite when its header or extension says so.
    func openFile(_ url: URL) {
        if SQLiteFile.opens(url) {
            openSQLiteFile(url)
        } else if SQLiteFile.extensions.contains(url.pathExtension.lowercased()) {
            alert = .notice(title: Self.fileProblemTitle, message: "“\(url.lastPathComponent)” isn’t a SQLite database.")
        } else {
            openConnectionFile(url)
        }
    }

    /// File > New SQLite File… (⌃⌘N): a save panel, an empty file, then a window on it.
    func requestNewSQLiteFile() {
        let panel = NSSavePanel()
        panel.title = "New SQLite File"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Untitled.sqlite"
        panel.allowedContentTypes = Self.sqliteFileTypes.prefix(1).map { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        createSQLiteFile(at: url, replacing: true)
    }

    /// Makes the file and opens it. The save panel already asked about replacing one,
    /// so `replacing` moves the old file to the Trash first, never deleting it.
    @discardableResult
    func createSQLiteFile(at url: URL, replacing: Bool) -> Task<Void, Never>? {
        do {
            if replacing, FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            try SQLiteFile.create(url)
        } catch {
            alert = .notice(title: Self.fileProblemTitle, message: (error as? DatabaseError)?.message ?? error.localizedDescription)
            return nil
        }
        return openSQLiteFile(url)
    }

    /// Locate… under "Can’t find “demo.sqlite”": points the form, and the saved connection, at the file.
    func locateSQLiteFile(model: AppModel) {
        guard let url = Self.chooseSQLiteFile(title: "Locate “\(form.fileURL?.lastPathComponent ?? "the file")”") else { return }
        form.file = (url.path as NSString).abbreviatingWithTildeInPath
        if let uid = selectedSaved { selectedSaved = model.save(form, over: uid) }
        connect(model: model)
    }

    /// After a SQLite file opens: its first table on Content, or the empty sidebar's New Table hint.
    func showFirstTable() async {
        guard isSQLite, pendingPlace == nil, selectedObjectID == nil,
              let first = objects.first(where: { $0.kind == .table }) ?? objects.first else { return }
        isNavigating = true
        selectedObjectID = first.id
        view = .content
        isNavigating = false
        reloadCurrentView(force: true)
        await currentLoad?.value
    }
}
