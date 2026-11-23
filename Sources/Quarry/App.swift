import AppKit
import QuarryKit
import SwiftData
import SwiftUI

// Quarry
//   Quarry                      the app
//   APP_STORE=<file> Quarry     use another store for saved connections (tests, experiments)
//   APP_SNAPSHOT=<dir> Quarry   save a PNG of every page and Settings tab in light and dark mode, then quit
//   APP_SEED=1 Quarry           fill an empty /tmp store with sample connections (tools/snap.sh)
//   Quarry --selftest           run the self-test against the test server and quit with 0 or 1 (tools/selftest.sh)
//   APP_ACCENT=<id> Quarry      run with another accent from Theme.all (UI/Theme.swift)
//   APP_GRID=1 Quarry           draw the 4 pt grid and the layout probes over the window
//   Quarry mcp                  the MCP bridge an agent runs (S-063; Main.swift)

struct QuarryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(container: Store.makeContainer())

    var body: some Scene {
        WindowGroup(id: WindowRoot.sceneID) {
            WindowRoot()
                .environment(model)
                .themed()
                .overlay { if GridOverlay.enabled { GridOverlay() } }
                .frame(minWidth: Layout.sidebarMin + Layout.detailMin, minHeight: 480)
        }
        .modelContainer(model.container)
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            QuarryCommands(state: MenuState.shared, model: model)
            TableCommands(state: MenuState.shared)
            QueryCommands(state: MenuState.shared, model: model)
        }

        // S-034: Manage Saved Queries… (⌃⌥⌘S).
        Window("Saved Queries", id: SavedQueriesWindow.sceneID) {
            SavedQueriesWindow()
                .environment(model)
                .themed()
        }
        .modelContainer(model.container)
        .defaultSize(width: 760, height: 480)
        .commandsRemoved()

        // S-039: Show Console (⇧⌘K), every statement from every window.
        Window("Console", id: ConsoleWindow.sceneID) {
            ConsoleWindow()
                .themed()
        }
        .defaultSize(width: 860, height: 420)
        .commandsRemoved()

        // S-065: Window > MCP Activity (⌥⇧⌘M).
        Window("MCP Activity", id: MCPActivityWindow.sceneID) {
            MCPActivityWindow()
                .environment(model)
                .themed()
        }
        .defaultSize(width: 1040, height: 480)
        .commandsRemoved()

        // S-053: Show Server Processes… (⌥⌘P), one window per connection window.
        WindowGroup("Server Processes", id: ProcessListWindow.sceneID, for: UUID.self) { $id in
            ProcessListWindow(listID: id)
                .themed()
        }
        .defaultSize(width: 960, height: 440)
        .commandsRemoved()

        // S-057: Quarry > About Quarry.
        Window("About Quarry", id: AboutWindow.sceneID) {
            AboutWindow()
                .themed()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commandsRemoved()

        // S-040: Help > Keyboard Shortcuts (⌘?), the command map.
        Window("Keyboard Shortcuts", id: KeyboardShortcutsWindow.sceneID) {
            KeyboardShortcutsWindow()
                .themed()
        }
        .defaultSize(width: 600, height: 640)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(model)
                .themed()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // AppKit catches an Objective-C exception and carries on, but the throw has
        // already skipped the cleanup of the Swift frames it unwound through, so the app
        // crashes later somewhere unrelated (docs/FIXLOG.md). In the self-test, crash
        // where the exception is thrown instead.
        if SelfTest.requested {
            UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
        }
        // Tests and snapshots start from one window, never the tabs a run left open.
        if SelfTest.requested || !(ProcessInfo.processInfo.environment["APP_SNAPSHOT"] ?? "").isEmpty {
            UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.startSyncing()
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Started from a terminal (tools/selftest.sh, tools/snap.sh), no "open
        // application" event arrives, so the WindowGroup opens no window. Ask
        // SwiftUI's delegate for one, the same call a Dock launch makes.
        DispatchQueue.main.async {
            guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
        }
    }

    /// S-068: a SQLite file dropped on the Dock icon or opened from the Finder;
    /// S-055's connection files too. The key window takes it when it shows the
    /// Connect page, else it opens in a new tab.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            // A launch by opening a file has no window yet.
            for _ in 0..<100 where MenuState.shared.active == nil { try? await Task.sleep(for: .milliseconds(20)) }
            for url in urls {
                if let session = MenuState.shared.active { session.openFile(url) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        // SSH tunnels are child processes that would outlive the app (S-047).
        TunnelPool.shared.stopAll()
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// Where saved connections live: ~/Library/Application Support/Quarry/Quarry.store
nonisolated enum Store {
    /// True when APP_STORE points somewhere else (tests, snapshots, seed data).
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }

    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["APP_STORE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let dir = URL.applicationSupportDirectory.appending(path: "Quarry", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "Quarry.store")
    }

    /// Every model in the store. A new model with defaults needs no migration.
    static let schema = Schema([SavedConnection.self, ConnectionGroup.self, FavoriteDatabase.self, SavedFilter.self, QueryHistoryEntry.self, SavedQuery.self, AgentToken.self, AgentRequest.self])

    static func makeContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
        } catch {
            fatalError("Could not open the store at \(url.path): \(error)")
        }
    }
}
