import Foundation
import Testing
@testable import QuarryKit

struct CommandMapTests {
    @Test func noTwoCommandsShowingTogetherShareAShortcut() {
        #expect(CommandMap.clashes() == [])
    }

    @Test func clashesFindsSharedShortcutsPerView() {
        let commands = [MenuCommand("Table", "A", "⌥⌘A", view: "Content"), MenuCommand("Table", "B", "⌥⌘A", view: "Structure"),
                        MenuCommand("File", "C", "⌘N"), MenuCommand("Table", "D", "⌘N", view: "Info")]
        #expect(CommandMap.clashes(in: commands) == ["⌘N: File > C, Table > D"])
    }

    @Test func everyCommandIsInAKnownMenuOnce() {
        #expect(CommandMap.all.allSatisfy { CommandMap.menus.contains($0.menu) })
        #expect(CommandMap.all.allSatisfy { $0.view.map(CommandMap.views.contains) ?? true })
        #expect(Set(CommandMap.all.map(\.id)).count == CommandMap.all.count)
    }

    @Test func shortcutsAreWrittenInApplesOrder() {
        let pattern = /^⌃?⌥?⇧?⌘?(.|↩|⌫|⎋|↑|↓|←|→)$/
        for command in CommandMap.all where !command.shortcut.isEmpty {
            #expect(command.shortcut.wholeMatch(of: pattern) != nil, "\(command.title): \(command.shortcut)")
        }
    }

    @Test func menuItemKeysReadAsMenusShowThem() {
        #expect(ShortcutText.text(key: "n", modifiers: [.command, .shift, .option]) == "⌥⇧⌘N")
        #expect(ShortcutText.text(key: "N", modifiers: [.command]) == "⇧⌘N")
        #expect(ShortcutText.text(key: "\u{8}", modifiers: [.command, .control]) == "⌃⌘⌫")
        #expect(ShortcutText.text(key: "\u{F701}", modifiers: [.command, .option]) == "⌥⌘↓")
        #expect(ShortcutText.text(key: "\u{1B}", modifiers: [.option]) == "⌥⎋")
        #expect(ShortcutText.text(key: "\r", modifiers: [.command]) == "⌘↩")
        #expect(ShortcutText.text(key: "?", modifiers: [.command]) == "⌘?")
        #expect(ShortcutText.text(key: "", modifiers: [.command]) == "")
    }

    /// docs/DESIGN.md §4 and the code say the same: each row's commands have its shortcut.
    @Test func designDocumentAgrees() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "docs/DESIGN.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let section = text.components(separatedBy: "## 4. Command map").last?.components(separatedBy: "\n## ").first ?? ""
        var checked = 0
        for line in section.split(separator: "\n") where line.hasPrefix("| ") && !line.hasPrefix("| Command") && !line.hasPrefix("| ---") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 4 else { continue }
            let titles = cells[1].components(separatedBy: " / ")
            let shortcuts = cells[3].components(separatedBy: " / ")
            for (index, title) in titles.enumerated() {
                let shortcut = shortcuts.count == titles.count ? shortcuts[index] : shortcuts[0]
                guard shortcut != "–", !shortcut.contains("…"), !title.contains("▸") else { continue }
                let command = CommandMap.all.first { $0.menu == cells[2] && $0.titles.contains(title) }
                #expect(command != nil, "DESIGN.md lists \(cells[2]) > \(title), the command map doesn't")
                #expect(command?.shortcut == shortcut, "\(title): DESIGN.md says \(shortcut), the command map \(command?.shortcut ?? "nothing")")
                checked += 1
            }
        }
        #expect(checked > 40)
    }
}
