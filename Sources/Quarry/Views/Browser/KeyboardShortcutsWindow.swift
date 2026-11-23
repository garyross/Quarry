import QuarryKit
import SwiftUI

/// Help > Keyboard Shortcuts (⌘?, S-040): every menu command and its shortcut,
/// menu by menu, from `CommandMap`. Filter by name or by shortcut.
struct KeyboardShortcutsWindow: View {
    static let sceneID = "keyboard-shortcuts"

    @State private var search = ""

    private var sections: [(menu: String, commands: [MenuCommand])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return CommandMap.menus.compactMap { menu in
            let commands = CommandMap.all.filter { command in
                command.menu == menu && (query.isEmpty
                    || command.titles.contains { $0.localizedCaseInsensitiveContains(query) }
                    || command.shortcut.localizedCaseInsensitiveContains(query))
            }
            return commands.isEmpty ? nil : (menu, commands)
        }
    }

    var body: some View {
        let sections = sections
        List {
            ForEach(sections, id: \.menu) { section in
                Section(section.menu) {
                    ForEach(section.commands) { command in
                        row(command)
                    }
                }
            }
        }
        .overlay {
            if sections.isEmpty { ContentUnavailableView.search(text: search) }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter")
        .frame(minWidth: Layout.shortcutsMinWidth, minHeight: Layout.shortcutsMinHeight)
        .noInitialFocus()
    }

    private func row(_ command: MenuCommand) -> some View {
        HStack(spacing: Space.sm) {
            Text(command.title)
            if let view = command.view {
                Text("on \(view)")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.lg)
            Text(command.shortcut.isEmpty ? "—" : command.shortcut)
                .foregroundStyle(.secondary)
                .accessibilityLabel(command.shortcut.isEmpty ? "No shortcut" : command.shortcut)
        }
    }
}
