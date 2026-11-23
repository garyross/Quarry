import AppKit
import QuarryKit
import UniformTypeIdentifiers

/// The Connect page's commands on saved connections (S-049), shared by the
/// Connection menu and the sidebar's menus.
extension Session {
    /// A new window or tab selects the default connection, else the one used last.
    func showInitialConnection(model: AppModel) {
        guard phase == .disconnected, selectedSaved == nil, selectedFavorite == nil, form == ConnectionDetails(),
              let initial = model.initialConnection() else { return }
        show(saved: initial)
        // S-054: Settings > General's Connect on launch, for the first window only.
        if Self.mayConnectOnLaunch(initial) { connect(model: model) }
    }

    /// Only once per launch, only the default connection, and never in tests or snapshots.
    private static var launchConnectionTried = false

    static func mayConnectOnLaunch(_ connection: SavedConnection) -> Bool {
        guard !launchConnectionTried else { return false }
        launchConnectionTried = true
        let testing = SelfTest.requested || !(ProcessInfo.processInfo.environment["APP_SNAPSHOT"] ?? "").isEmpty
        return Preferences.connectOnLaunch && connection.isDefault && !testing
    }

    func newConnectionGroup(model: AppModel) {
        let group = model.newGroup(moving: selectedSaved)
        renamingConnection = nil
        renamingGroup = group.uid
    }

    func renameSelectedConnection() {
        guard let selectedSaved else { return }
        renamingGroup = nil
        renamingConnection = selectedSaved
    }

    func duplicateSelectedConnection(model: AppModel) {
        guard let selectedSaved, let copy = model.duplicateConnection(selectedSaved) else { return }
        show(saved: copy)
    }

    func requestDeleteSelectedConnection() {
        pendingDeleteSaved = selectedSaved
    }

    /// Deletes the connection Delete asked about.
    func deletePendingConnection(model: AppModel) {
        guard let uid = pendingDeleteSaved else { return }
        if selectedSaved == uid { show(saved: nil) }
        model.delete(uid)
        pendingDeleteSaved = nil
    }

    /// Export Connections…: a save panel, then Sequel Pro's favorites file.
    func exportConnections(model: AppModel) {
        let panel = NSSavePanel()
        panel.title = "Export Connections"
        panel.message = "Passwords are not exported."
        panel.nameFieldStringValue = "Quarry Connections.plist"
        panel.allowedContentTypes = [.propertyList]
        present(panel) { [weak self] url in
            do {
                try model.exportConnections().write(to: url, options: .atomic)
            } catch {
                self?.alert = .notice(title: "Could Not Export Connections", message: error.localizedDescription)
            }
        }
    }

    /// Import Connections…: an open panel, then the file's connections beside the ones here.
    func importConnections(model: AppModel) {
        let panel = NSOpenPanel()
        panel.title = "Import Connections"
        panel.message = "Choose a connections file that Quarry or Sequel Pro exported."
        panel.allowedContentTypes = [.propertyList]
        present(panel) { [weak self] url in
            self?.importConnections(from: url, model: model)
        }
    }

    func importConnections(from url: URL, model: AppModel) {
        do {
            let data = try Data(contentsOf: url)
            let summary = try model.importConnections(data)
            alert = .notice(title: summary, message: "Enter their passwords before connecting.")
        } catch let error as ConnectionFile.ImportError {
            alert = .notice(title: "Could Not Import Connections", message: error.localizedDescription)
        } catch {
            alert = .notice(title: "Could Not Import Connections", message: error.localizedDescription)
        }
    }

    private func present(_ panel: NSSavePanel, then use: @escaping (URL) -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            use(url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }
}
