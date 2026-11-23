import AppKit
import QuarryKit

/// Settings people change in Settings (S-054), read where they apply. Each
/// reader falls back to the default when nothing is stored. Views that draw
/// with them (the grid, the editor) listen for `UserDefaults.didChangeNotification`,
/// so a change shows at once, without a relaunch.
enum Preferences {
    enum Key {
        static let connectOnLaunch = "general.connectOnLaunch"
        static let firstView = "general.firstView"
        static let logStatements = "general.logStatements"
        static let nullText = "tables.nullText"
        static let monospaced = "tables.monospaced"
        static let gridSize = "tables.fontSize"
        static let gridLines = "tables.gridLines"
        static let editorSize = "editor.fontSize"
        static let tabWidth = "editor.tabWidth"
    }

    private static var defaults: UserDefaults { .standard }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private static func number(_ key: String, _ fallback: Int, in range: ClosedRange<Int>) -> Int {
        let stored = defaults.integer(forKey: key)
        return range.contains(stored) ? stored : fallback
    }

    // MARK: General

    /// The first window after launch connects to the default connection.
    static var connectOnLaunch: Bool { bool(Key.connectOnLaunch, false) }

    /// The view a new window or tab starts on; switching tables keeps the view in use.
    static var firstView: DetailView {
        defaults.string(forKey: Key.firstView).flatMap(DetailView.init(rawValue:)) ?? .content
    }

    static let firstViews: [DetailView] = [.structure, .content, .info, .query]

    /// Statements go to the Console (S-039); off, it records only errors.
    static var logStatements: Bool { bool(Key.logStatements, true) }

    // MARK: Tables

    static let defaultNullText = "NULL"

    /// How the grid shows NULL. Copy and export keep their own NULL text.
    static var nullText: String {
        let stored = defaults.string(forKey: Key.nullText)?.trimmingCharacters(in: .whitespaces) ?? ""
        return stored.isEmpty ? defaultNullText : stored
    }

    static var monospaced: Bool { bool(Key.monospaced, true) }
    static let gridSizes = [10, 11, 12, 13, 14, 16]
    static var gridSize: Int { number(Key.gridSize, 12, in: 10...18) }
    static var gridLines: Bool { bool(Key.gridLines, true) }

    // MARK: Editor

    static let editorSizes = [11, 12, 13, 14, 16, 18]
    static var editorSize: Int { number(Key.editorSize, 13, in: 10...24) }
    static let tabWidths = [2, 4, 8]
    static var tabWidth: Int { number(Key.tabWidth, 4, in: 1...16) }

    // MARK: Network

    static let timeouts = [5, 10, 20, 30, 60]

    /// Copies the settings QuarryKit reads (the Console, the connect timeout)
    /// whenever defaults change. Called once at launch.
    static func startSyncing() {
        sync()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { sync() }
        }
    }

    private static func sync() {
        ConsoleLog.shared.logsStatements = logStatements
    }
}
