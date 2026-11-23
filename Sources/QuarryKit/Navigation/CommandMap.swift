import Foundation

/// One menu bar command and its shortcut (S-040). `CommandMap.all` is the
/// command map of docs/DESIGN.md §4 in code: a unit test checks it against
/// that table, the self-test against the real menu bar, and Help > Keyboard
/// Shortcuts lists it.
public struct MenuCommand: Sendable, Hashable, Identifiable {
    /// The menu bar menu: "Quarry" is the app menu.
    public let menu: String
    public let title: String
    /// Glyphs in Apple's order, ⌃⌥⇧⌘ then the key, as menus show them; empty for none.
    public let shortcut: String
    /// Other titles the same item takes as the selection changes ("Remove from Favorites").
    public let also: [String]
    /// The view whose commands these are ("Structure"); nil when the item is always there.
    public let view: String?
    /// What a SQLite file lacks for this command ("user accounts"); nil when it
    /// works on every engine (S-068). The item grays out on a SQLite window.
    public let sqliteLacks: String?
    /// The one engine whose windows show the item at all (S-072): the Database
    /// menu lists only that engine's maintenance tools. nil: every window shows it.
    public let only: Engine?

    /// The engines the command works on.
    public var engines: Set<Engine> {
        if let only { return [only] }
        return sqliteLacks == nil ? Set(Engine.allCases) : [.mysql]
    }

    /// Whether a window on `engine` shows the item (grayed or not).
    public func isShown(on engine: Engine) -> Bool { only == nil || only == engine }

    /// The tooltip on the grayed item: "SQLite files have no server, so there are no user accounts."
    public var sqliteHelp: String? { sqliteLacks.map(Self.sqliteHelp) }

    public static func sqliteHelp(_ lacks: String) -> String { "SQLite files have no server, so there are no \(lacks)." }

    public var id: String { "\(menu)/\(title)/\(view ?? "")" }

    public init(_ menu: String, _ title: String, _ shortcut: String = "", also: [String] = [], view: String? = nil,
                sqliteLacks: String? = nil, only: Engine? = nil) {
        self.menu = menu
        self.title = title
        self.shortcut = shortcut
        self.also = also
        self.view = view
        self.sqliteLacks = sqliteLacks
        self.only = only
    }

    /// Every title the item may show.
    public var titles: [String] { [title] + also }
}

public enum CommandMap {
    /// Menus in menu bar order.
    public static let menus = ["Quarry", "File", "Edit", "View", "Connection", "Database", "Table", "Query", "Window", "Help"]

    /// Views whose Table menu items change, in toolbar order.
    public static let views = ["Structure", "Content", "Foreign Keys", "Triggers", "Info", "Query"]

    public static let all: [MenuCommand] = app + file + edit + view + connection + database + table + query + window + help

    static let app: [MenuCommand] = [
        .init("Quarry", "About Quarry"),
        .init("Quarry", "Settings…", "⌘,"),
        .init("Quarry", "Hide Quarry", "⌘H"),
        .init("Quarry", "Hide Others", "⌥⌘H"),
        .init("Quarry", "Quit Quarry", "⌘Q"),
    ]

    static let file: [MenuCommand] = [
        .init("File", "New Connection Window", "⌘N"),
        .init("File", "New Connection Tab", "⌘T"),
        .init("File", "Duplicate Connection Tab", "⇧⌘T"),
        .init("File", "New SQLite File…", "⌃⌘N"),
        .init("File", "Open…", "⌘O"),
        .init("File", "Save Connection", "⇧⌘A"),
        .init("File", "Save Connection File…", "⌘S"),
        .init("File", "Save Session…", "⇧⌘S"),
        .init("File", "Export…", "⇧⌘E"),
        .init("File", "Import…", "⇧⌘I"),
        .init("File", "Import from Clipboard…", "⌥⇧⌘I"),
        .init("File", "Close", "⌘W"),
    ]

    static let edit: [MenuCommand] = [
        .init("Edit", "Undo", "⌘Z"),
        .init("Edit", "Redo", "⇧⌘Z"),
        .init("Edit", "Cut", "⌘X"),
        .init("Edit", "Copy", "⌘C"),
        .init("Edit", "Paste", "⌘V"),
        .init("Edit", "Select All", "⌘A"),
        .init("Edit", "Copy with Column Names", "⌥⌘C"),
        .init("Edit", "Copy as SQL INSERT", "⌃⌥⌘C"),
        .init("Edit", "Set to NULL", "⌃⇧N"),
    ]

    static let view: [MenuCommand] = [
        .init("View", "Structure", "⌘1"),
        .init("View", "Content", "⌘2"),
        .init("View", "Foreign Keys", "⌘3"),
        .init("View", "Triggers", "⌘4"),
        .init("View", "Info", "⌘5"),
        .init("View", "Query", "⌘6"),
        .init("View", "Back", "⌃⌥←"),
        .init("View", "Forward", "⌃⌥→"),
        .init("View", "Previous Page", "⌥⌘["),
        .init("View", "Next Page", "⌥⌘]"),
        .init("View", "Refresh", "⇧⌘R"),
        .init("View", "Filter Sidebar", "⌥⌘F"),
        .init("View", "Show Console", "⇧⌘K"),
        .init("View", "Clear Console", "⌥⌘K"),
        .init("View", "Hide Sidebar", "⌃⌘S", also: ["Show Sidebar"]),
        .init("View", "Hide Toolbar", "⌥⌘T", also: ["Show Toolbar"]),
    ]

    static let connection: [MenuCommand] = [
        .init("Connection", "Connect", "⌘↩"),
        .init("Connection", "Test Connection"),
        .init("Connection", "Rename Connection"),
        .init("Connection", "Duplicate Connection", "⌃⌥⌘D"),
        .init("Connection", "Color"),
        .init("Connection", "Red"),
        .init("Connection", "Orange"),
        .init("Connection", "Yellow"),
        .init("Connection", "Green"),
        .init("Connection", "Blue"),
        .init("Connection", "Purple"),
        .init("Connection", "Gray"),
        .init("Connection", "None"),
        .init("Connection", "Move to Group"),
        .init("Connection", "Default Connection"),
        .init("Connection", "Delete Connection…"),
        .init("Connection", "New Group", "⌃⌥⌘N"),
        .init("Connection", "Sort By"),
        .init("Connection", "Manual"),
        .init("Connection", "Name"),
        .init("Connection", "Host"),
        .init("Connection", "Type"),
        .init("Connection", "Reverse Order"),
        .init("Connection", "Import Connections…"),
        .init("Connection", "Export Connections…"),
        .init("Connection", "Disconnect", "⌃⌘W"),
    ]

    static let database: [MenuCommand] = [
        .init("Database", "Go to Database…", "⇧⌘D"),
        .init("Database", "New Database…", "⇧⌘N", sqliteLacks: "other databases"),
        .init("Database", "Duplicate Database…", "⌥⇧⌘N", sqliteLacks: "other databases"),
        .init("Database", "Rename Database…", "⌥⇧⌘R", sqliteLacks: "other databases"),
        .init("Database", "Change Character Set…", "⌥⇧⌘C", sqliteLacks: "character sets"),
        .init("Database", "Delete Database…", "⇧⌘⌫", sqliteLacks: "other databases"),
        .init("Database", "Add to Favorites", "⌘D", also: ["Remove from Favorites"], sqliteLacks: "other databases"),
        .init("Database", "View Using Encoding", sqliteLacks: "other encodings"),
    ] + ViewEncoding.allCases.map { MenuCommand("Database", $0.title) } + [
        .init("Database", "Show Database Information", "⌥⌘I", also: ["Hide Database Information"]),
        .init("Database", "Show Server Variables…", "⇧⌘V", sqliteLacks: "server variables"),
        .init("Database", "Show Server Processes…", "⌥⌘P", sqliteLacks: "server processes"),
        .init("Database", "User Accounts…", "⌘U", sqliteLacks: "user accounts"),
        .init("Database", "Check Tables", only: .mysql),
        .init("Database", "Repair Tables…", only: .mysql),
        .init("Database", "Find Collations", only: .mysql),
        .init("Database", "Integrity Check", only: .sqlite),
        .init("Database", "Foreign Key Check", only: .sqlite),
        .init("Database", "Health Check"),
        .init("Database", "Analyze", only: .sqlite),
        .init("Database", "Optimize", only: .sqlite),
        .init("Database", "Vacuum…", only: .sqlite),
    ]

    static let table: [MenuCommand] = [
        .init("Table", "New Table…", "⌥⌘N"),
        .init("Table", "New View…", "⌃⌥⌘V"),
        .init("Table", "New Procedure…", "⌃⌥⌘P", sqliteLacks: "procedures"),
        .init("Table", "New Function…", "⌃⌥⌘U", sqliteLacks: "stored functions"),
        .init("Table", "Edit View…", "⌃⌥⌘E", also: ["Edit Procedure…", "Edit Function…"]),
        .init("Table", "Rename Table…", "⌃⌘R", also: ["Rename View…", "Rename Procedure…", "Rename Function…"]),
        .init("Table", "Duplicate Table…", "⌃⌘D"),
        .init("Table", "Empty Table…", "⌃⌘⌫"),
        .init("Table", "Delete Table…", "⌥⌘⌫", also: ["Delete View…", "Delete Procedure…", "Delete Function…"]),
        .init("Table", "Show Create Statement…", "⌃⌘C"),
        .init("Table", "Copy Create Statement", "⇧⌘C"),
        .init("Table", "Maintenance"),
        .init("Table", "Check Table"),
        .init("Table", "Repair Table", sqliteLacks: "server maintenance tools"),
        .init("Table", "Analyze Table"),
        .init("Table", "Optimize Table", sqliteLacks: "server maintenance tools"),
        .init("Table", "Flush Table", sqliteLacks: "server maintenance tools"),
        .init("Table", "Checksum Table", sqliteLacks: "server maintenance tools"),
        .init("Table", "Filter Content", "⌘F"),
        .init("Table", "Add Filter Rule", "⇧⌘F"),
        .init("Table", "Add Filter Group", "⌥⇧⌘F"),
        .init("Table", "Add WHERE Clause", "⌃⌥⌘F"),
        .init("Table", "Save Filter…", "⌥⌘S"),
        .init("Table", "Saved Filters"),
        .init("Table", "Clear Filter"),
        .init("Table", "Open in Field Editor", "⌃⌘E"),
        .init("Table", "Open Referenced Row", "⌘↓"),
        .init("Table", "Open Referenced Row in New Tab", "⌥⌘↓"),
        .init("Table", "Open Table in New Tab", "⌃⌘T", also: ["Open View in New Tab", "Open Procedure in New Tab", "Open Function in New Tab"]),
        .init("Table", "Add Row", "⌥⌘A", view: "Content"),
        .init("Table", "Duplicate Row", "⌥⇧⌘D", view: "Content"),
        .init("Table", "Delete Row…", "⌘⌫", view: "Content"),
        .init("Table", "Edit Field…", "⌥⌘E", view: "Structure"),
        .init("Table", "Add Field…", "⌥⌘A", view: "Structure"),
        .init("Table", "Duplicate Field", "⌥⇧⌘D", view: "Structure"),
        .init("Table", "Delete Field…", "⌘⌫", also: ["Delete Index…"], view: "Structure"),
        .init("Table", "Move Field Up", "⌃⌘↑", view: "Structure"),
        .init("Table", "Move Field Down", "⌃⌘↓", view: "Structure"),
        .init("Table", "Add Index…", "⌃⌥⌘A", view: "Structure"),
        .init("Table", "Add Foreign Key…", "⌥⌘A", view: "Foreign Keys"),
        .init("Table", "Delete Foreign Key…", "⌘⌫", view: "Foreign Keys"),
        .init("Table", "Add Trigger…", "⌥⌘A", view: "Triggers"),
        .init("Table", "Edit Trigger…", "⌥⌘E", view: "Triggers"),
        .init("Table", "Delete Trigger…", "⌘⌫", view: "Triggers"),
        .init("Table", "Reset Auto Increment", "⌃⌥⌘R", view: "Info"),
    ]

    static let query: [MenuCommand] = [
        .init("Query", "Run Current Statement", "⌘R"),
        .init("Query", "Run All", "⌥⌘R"),
        .init("Query", "Select Current Statement", "⌃Y"),
        .init("Query", "Show Completions", "⌥⎋"),
        .init("Query", "Comment Line", "⌘/"),
        .init("Query", "Comment Current Statement", "⌥⌘/"),
        // ⌘[ ⌘] are Back and Forward outside Query, so these take them only there.
        .init("Query", "Shift Right", "⌘]", view: "Query"),
        .init("Query", "Shift Left", "⌘[", view: "Query"),
        .init("Query", "Previous Query from History", "⌃⌥↑"),
        .init("Query", "Next Query from History", "⌃⌥↓"),
        .init("Query", "Show History", "⌃⌘H"),
        .init("Query", "Save Query…", "⌃⇧⌘S"),
        .init("Query", "Saved Queries"),
        .init("Query", "Manage Saved Queries…", "⌃⌥⌘S"),
        .init("Query", "Cancel Query", "⌘."),
    ]

    static let window: [MenuCommand] = [
        .init("Window", "Minimize", "⌘M"),
        .init("Window", "Zoom"),
        .init("Window", "Bring All to Front"),
        .init("Window", "MCP Activity", "⌥⇧⌘M"),
    ]

    static let help: [MenuCommand] = [
        .init("Help", "Keyboard Shortcuts", "⌘?"),
        .init("Help", "MySQL Reference Manual"),
        .init("Help", "MariaDB Documentation"),
    ]

    /// The commands of one menu for a view: the ones always there plus that view's.
    public static func commands(in menu: String, view: String?) -> [MenuCommand] {
        all.filter { $0.menu == menu && ($0.view == nil || $0.view == view) }
    }

    /// Shortcuts that two commands showing at the same time share.
    /// Each view's commands show with the ones that are always there.
    public static func clashes(in commands: [MenuCommand] = all) -> [String] {
        var found: [String] = []
        for view in [nil] + views.map(Optional.some) {
            let showing = commands.filter { !$0.shortcut.isEmpty && ($0.view == nil || $0.view == view) }
            let grouped = Dictionary(grouping: showing, by: \.shortcut)
            for (shortcut, group) in grouped where group.count > 1 {
                let line = "\(shortcut): " + group.map { "\($0.menu) > \($0.title)" }.joined(separator: ", ")
                if !found.contains(line) { found.append(line) }
            }
        }
        return found.sorted()
    }
}

/// A menu item's key equivalent as menus show it (S-040).
public enum ShortcutText {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// "⌥⇧⌘N" from an NSMenuItem's key equivalent and modifiers. A key typed
    /// with Shift ("N" rather than "n") counts as Shift, as AppKit draws it.
    public static func text(key: String, modifiers: Modifiers) -> String {
        guard let scalar = key.unicodeScalars.first else { return "" }
        var modifiers = modifiers
        var glyph: String
        switch scalar.value {
        case 0xF700: glyph = "↑"
        case 0xF701: glyph = "↓"
        case 0xF702: glyph = "←"
        case 0xF703: glyph = "→"
        case 0x08, 0x7F: glyph = "⌫"
        case 0xF728: glyph = "⌦"
        case 0x1B: glyph = "⎋"
        case 0x0D, 0x03: glyph = "↩"
        case 0x09: glyph = "⇥"
        case 0x20: glyph = "Space"
        default:
            glyph = key.uppercased()
            if key != key.lowercased() { modifiers.insert(.shift) }
        }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + glyph
    }
}
