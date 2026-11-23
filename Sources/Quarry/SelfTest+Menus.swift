import AppKit
import QuarryKit

/// S-040: the menu bar against the command map (`CommandMap`, docs/DESIGN.md §4).
extension SelfTest {
    /// A menu bar item as the walk finds it.
    struct WalkedItem {
        let menu: String
        let title: String
        let shortcut: String
        let isEnabled: Bool
        /// Inside a submenu whose items are the user's own (Saved Filters, Saved Queries).
        let isUserItem: Bool
    }

    /// Every visible item of the menu bar, after SwiftUI refreshes the menus as it does when one opens.
    static func walkMenuBar() -> [WalkedItem] {
        _ = menuItem("")  // refreshes every menu
        var walked: [WalkedItem] = []
        func walk(_ menu: NSMenu?, top: String, userItems: Bool) {
            for item in menu?.items ?? [] where !item.isSeparatorItem && !item.isHidden && !item.title.isEmpty {
                let modifiers = item.keyEquivalentModifierMask
                var mask: ShortcutText.Modifiers = []
                if modifiers.contains(.control) { mask.insert(.control) }
                if modifiers.contains(.option) { mask.insert(.option) }
                if modifiers.contains(.shift) { mask.insert(.shift) }
                if modifiers.contains(.command) { mask.insert(.command) }
                walked.append(WalkedItem(menu: top, title: item.title,
                                         shortcut: ShortcutText.text(key: item.keyEquivalent, modifiers: mask),
                                         isEnabled: item.isEnabled, isUserItem: userItems))
                walk(item.submenu, top: top, userItems: userItems || ["Saved Filters", "Saved Queries", "Move to Group"].contains(item.title))
            }
        }
        for (index, top) in (NSApp.mainMenu?.items ?? []).enumerated() {
            walk(top.submenu, top: index == 0 ? "Quarry" : top.title, userItems: false)
        }
        return walked
    }

    static func menuBar(model: AppModel, session: Session) async {
        session.database = "quarry_demo"
        await session.currentLoad?.value
        session.selectedObjectID = "table:orders"
        await session.currentLoad?.value
        check("S-040 the command map has no clashing shortcuts", CommandMap.clashes().isEmpty,
              CommandMap.clashes().joined(separator: "; "))

        let order: [DetailView] = [.content, .structure, .foreignKeys, .triggers, .info, .query]
        for view in order {
            session.view = view
            await session.currentLoad?.value
            try? await Task.sleep(for: .milliseconds(300))
            let walked = walkMenuBar()
            var wrong: [String] = []
            for menu in CommandMap.menus {
                for command in CommandMap.commands(in: menu, view: view.title) where command.isShown(on: .mysql) {
                    let items = walked.filter { $0.menu == menu && command.titles.contains($0.title) }
                    if items.isEmpty {
                        wrong.append("\(menu) > \(command.title) is missing")
                    } else if !items.contains(where: { $0.shortcut == command.shortcut }) {
                        wrong.append("\(menu) > \(command.title) is \(items[0].shortcut.isEmpty ? "without a shortcut" : items[0].shortcut), not \(command.shortcut)")
                    }
                }
            }
            check("S-040 on \(view.title), every command is in its menu with its shortcut", wrong.isEmpty,
                  wrong.joined(separator: "; "))

            // One shortcut, one item, among everything the menu bar shows.
            let clashes = Dictionary(grouping: walked.filter { !$0.shortcut.isEmpty }, by: \.shortcut)
                .filter { $0.value.count > 1 }
                .map { "\($0.key): " + $0.value.map { "\($0.menu) > \($0.title)" }.joined(separator: ", ") }
                .sorted()
            check("S-040 on \(view.title), no two menu items share a shortcut", clashes.isEmpty, clashes.joined(separator: "; "))

            // Quarry's own menus hold nothing the map leaves out.
            let known = Set(CommandMap.all.flatMap(\.titles))
            let unknown = walked.filter {
                ["Connection", "Database", "Table", "Query", "Help"].contains($0.menu) && !$0.isUserItem && !known.contains($0.title)
            }
            check("S-040 on \(view.title), the command map lists every item of Quarry's menus", unknown.isEmpty,
                  unknown.map { "\($0.menu) > \($0.title)" }.joined(separator: ", "))
        }

        // Items gray out when they do not apply: Edit's grid commands need a grid.
        func enabled(_ title: String) -> Bool { walkMenuBar().first { $0.title == title }?.isEnabled ?? false }
        session.view = .content
        await session.currentLoad?.value
        try? await Task.sleep(for: .milliseconds(300))
        session.window?.makeFirstResponder(nil)
        MenuState.shared.refreshResponder()
        await until { !enabled("Copy with Column Names") }
        check("S-040 with no grid focused, Edit's grid commands are off",
              !enabled("Copy with Column Names") && !enabled("Copy as SQL INSERT") && !enabled("Set to NULL")
                  && !enabled("Open in Field Editor"))
        if let grid = session.window.flatMap({ gridTable(in: $0) }) {
            session.window?.makeFirstResponder(grid)
            grid.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            // A click would end with NSApplication's update, which refreshes this.
            MenuState.shared.refreshResponder()
            await until { enabled("Copy with Column Names") }
            check("S-040 with a row selected in the grid, Copy with Column Names and Copy as SQL INSERT are on",
                  enabled("Copy with Column Names") && enabled("Copy as SQL INSERT") && !enabled("Set to NULL"),
                  "grid can copy: \(grid.canPerform(#selector(GridCopying.copyWithColumnNames(_:)))), key: \(NSApp.keyWindow === session.window), "
                      + "target: \(NSApp.target(forAction: #selector(GridCopying.copyWithColumnNames(_:)), to: nil, from: nil).map { String(describing: type(of: $0)) } ?? "none"), "
                      + "responder: \(MenuState.shared.responder)")
        } else {
            check("S-040 Content's grid is in the window", false)
        }
        Console.shared.clear()
        await until { Console.shared.messages.isEmpty }
        check("S-040 Clear Console is off while the Console is empty", !enabled("Clear Console"))

        // File > Duplicate Connection Tab: the same server, database, table and view.
        session.view = .structure
        let before = Tabs.lastOpened
        session.duplicateTab()
        guard let tab = await openedTab(after: before) else {
            check("S-040 Duplicate Connection Tab opens a tab", false)
            return
        }
        await tab.waitForConnect()
        await until { tab.selectedObjectID == "table:orders" && tab.view == .structure }
        check("S-040 Duplicate Connection Tab opens the same table and view on its own connection",
              tab.phase == .connected && tab.database == "quarry_demo" && tab.selectedObjectID == "table:orders"
                  && tab.view == .structure && tab.client !== session.client,
              "\(tab.phase) \(tab.database ?? "nil") \(tab.selectedObjectID ?? "nil") \(tab.view)")
        closeTab(tab)
        session.window?.makeKeyAndOrderFront(nil)
        session.view = .content
    }

    /// The first data grid in a window.
    static func gridTable(in window: NSWindow) -> GridTableView? {
        ViewTree.first(GridTableView.self, in: window.contentView) { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
    }
}
