import AppKit
import QuarryKit
import UniformTypeIdentifiers

/// Connection and session files (S-055): File > Open…, Save Connection File…, Save Session….
extension Session {
    /// The notice when Open… or Save fails (S-055, S-068).
    static let fileProblemTitle = "Couldn’t Open or Save the File"

    static var connectionFileType: UTType { UTType(filenameExtension: ConnectionDocument.connectionExtension) ?? .propertyList }
    static var sessionFileType: UTType { UTType(filenameExtension: ConnectionDocument.sessionExtension) ?? .propertyList }

    /// This window as a file's tab: how it connected, where it is, and its query text.
    var fileTab: ConnectionDocument.Tab? {
        guard phase == .connected, var details = connectedDetails else { return nil }
        if let database { details.database = database }
        let color = selectedSaved.flatMap { model?.savedConnection($0)?.colorIndex } ?? -1
        return ConnectionDocument.Tab(details: details, colorIndex: color, table: selectedObject?.name,
                                      view: SavedView.name(for: view.rawValue), query: query.text)
    }

    /// ⌘S (one connection) or ⇧⌘S (every connected tab, window by window).
    func requestSaveConnectionFile(asSession: Bool) {
        guard phase == .connected, connectionFileDraft == nil else { return }
        let summary: String
        if asSession {
            let windows = Tabs.connectedWindows()
            let tabs = windows.reduce(0) { $0 + $1.count }
            summary = "\(tabs == 1 ? "1 tab" : "\(tabs) tabs") in \(windows.count == 1 ? "1 window" : "\(windows.count) windows")"
        } else {
            summary = connectedDetails?.displayName ?? ""
        }
        connectionFileDraft = ConnectionFileDraft(asSession: asSession, summary: summary)
    }

    /// The document Save writes: this window, or every connected tab for a session.
    func connectionDocument(asSession: Bool, connectsOnOpen: Bool) -> ConnectionDocument {
        let windows = asSession ? Tabs.connectedWindows().map { $0.compactMap(\.fileTab) } : [fileTab].compactMap { $0.map { [$0] } }
        return ConnectionDocument(windows: windows.filter { !$0.isEmpty }, connectsOnOpen: connectsOnOpen)
    }

    /// Save… in the sheet: a save panel, then the file.
    func chooseConnectionFileDestination() {
        guard let draft = connectionFileDraft, draft.canSave else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [draft.asSession ? Self.sessionFileType : Self.connectionFileType]
        panel.nameFieldStringValue = draft.asSession ? "Session" : (connectedDetails?.displayName ?? "Connection")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writeConnectionFile(to: url)
        } catch {
            alert = .notice(title: Self.fileProblemTitle, message: error.localizedDescription)
        }
    }

    func writeConnectionFile(to url: URL) throws {
        guard let draft = connectionFileDraft else { return }
        let document = connectionDocument(asSession: draft.asSession, connectsOnOpen: draft.options.connectsOnOpen)
        let password = draft.options.includesPasswords ? draft.password : nil
        let data = try document.encoded(draft.options, password: password, asSession: draft.asSession)
        try data.write(to: url, options: .atomic)
        draft.remember()
        connectionFileDraft = nil
    }

    /// File > Open… (⌘O): a connection or session file, from Quarry or Sequel Pro.
    func chooseConnectionFile() {
        let panel = NSOpenPanel()
        // S-068: SQLite files open here too.
        panel.allowedContentTypes = [Self.connectionFileType, Self.sessionFileType] + Self.sqliteFileTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(url)
    }

    func openConnectionFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            alert = .notice(title: Self.fileProblemTitle, message: "Quarry couldn’t read “\(url.lastPathComponent)”.")
            return
        }
        if ConnectionDocument.isEncrypted(data) {
            fileUnlock = FileUnlock(url: url, data: data)
            return
        }
        do {
            open(try ConnectionDocument.decode(data))
        } catch {
            alert = .notice(title: Self.fileProblemTitle, message: error.localizedDescription)
        }
    }

    /// Open in the password sheet. A wrong password keeps the sheet up with its message.
    func unlockConnectionFile() {
        guard let unlock = fileUnlock else { return }
        do {
            let document = try ConnectionDocument.decode(unlock.data, password: unlock.password)
            fileUnlock = nil
            open(document)
        } catch {
            unlock.error = error.localizedDescription
        }
    }

    /// The first tab opens here when this window is on the Connect page with
    /// nothing connected; every other tab opens beside it, and each further
    /// window's tabs in a new window. The task ends once every tab was asked for (self-test).
    @discardableResult
    func open(_ document: ConnectionDocument) -> Task<Void, Never> {
        let connect = document.connectsOnOpen
        var windows = document.windows
        let here = phase == .disconnected ? windows[0].removeFirst() : nil
        if let here { load(here, connect: connect, model: model) }
        let anchor = window
        return Task {
            for (index, tabs) in windows.enumerated() {
                var parent: NSWindow? = index == 0 ? (here == nil ? nil : anchor) : nil
                for tab in tabs {
                    let before = Tabs.lastOpenedWindow
                    Tabs.open(beside: parent, using: openWindowAction) { session, model in session.load(tab, connect: connect, model: model) }
                    for _ in 0..<100 where Tabs.lastOpenedWindow === before {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    parent = Tabs.lastOpenedWindow
                }
            }
        }
    }

    /// Fills the form from a file's tab, keeps where to go and the query text, and connects if the file says so.
    func load(_ tab: ConnectionDocument.Tab, connect: Bool, model: AppModel?) {
        selectedSaved = nil
        selectedFavorite = nil
        form = tab.details
        if let text = tab.query { query.text = text }
        let view = tab.view.flatMap(SavedView.view(for:)).flatMap(DetailView.init(rawValue:)) ?? Preferences.firstView
        if !tab.details.database.isEmpty {
            pendingPlace = Place(database: tab.details.database,
                                 objectID: tab.table.map { DBObject(name: $0, kind: .table).id }, view: view, content: nil)
        }
        if connect { self.connect(model: model ?? self.model) }
    }
}
