import AppKit
import QuarryKit
import SwiftData

/// Self-test: organizing saved connections on the Connect page (S-049).
extension SelfTest {
    static func organizingConnections(model: AppModel, session: Session) async {
        session.disconnect()
        let local = model.save(SeedData.local, over: nil)
        let socket = model.save(SeedData.localSocket, over: nil)
        session.show(saved: model.savedConnection(local))

        // Groups
        session.newConnectionGroup(model: model)
        let first = model.connectionGroups().first { $0.uid == session.renamingGroup }
        check("S-049 New Group makes \"New Group\", ready to rename, with the selected connection in it",
              first?.name == "New Group" && model.savedConnection(local)?.groupID == first?.uid)
        session.renamingGroup = nil
        guard let first else { return }
        model.renameGroup(first.uid, to: "  Work  ")
        let second = model.newGroup(moving: nil)
        check("S-049 group names are trimmed and the next new group is numbered",
              first.name == "Work" && second.name == "New Group")
        model.move(socket, toGroup: second.uid)
        check("S-049 Move to Group moves a connection", model.savedConnection(socket)?.groupID == second.uid)
        model.deleteGroup(second.uid)
        check("S-049 Delete Group keeps its connections at the top level",
              model.savedConnection(socket)?.groupID == nil && !model.connectionGroups().contains { $0.uid == second.uid })

        // Color, and both survive a store reload
        model.setColor(.red, of: local)
        let reopened = try? ModelContainer(for: Store.schema, configurations: ModelConfiguration(url: Store.url))
        let fresh = reopened.flatMap { try? ModelContext($0).fetch(FetchDescriptor<SavedConnection>()) }?.first { $0.uid == local }
        check("S-049 a color and a group survive a store reload", fresh?.colorIndex == 0 && fresh?.groupID == first.uid)

        // The Connection menu follows the selection
        try? await Task.sleep(for: .milliseconds(300))
        let red = menuItem("Red")
        let duplicate = menuItem("Duplicate Connection")
        check("S-049 the Connection menu checks the color and enables Duplicate Connection (⌃⌥⌘D)",
              red?.state == .on && duplicate?.isEnabled == true
                  && duplicate?.keyEquivalentModifierMask == [.command, .option, .control],
              "Red \(String(describing: red?.state)), Duplicate \(String(describing: duplicate?.isEnabled))")

        // Duplicate
        session.duplicateSelectedConnection(model: model)
        let copy = model.savedConnection(session.selectedSaved)
        check("S-049 Duplicate makes \"Local Copy\" in the same group with the same color, selected",
              copy?.name == "Local Copy" && copy?.groupID == first.uid && copy?.colorIndex == 0 && copy?.uid != local,
              copy?.name ?? "nothing")
        check("S-049 the copy has the Keychain password", copy.map { PasswordStore.password(for: $0.uid) } == "quarry")
        let shown = model.ordered(model.savedConnections().filter { $0.groupID == first.uid })
        check("S-049 the copy comes right after the original in Manual order",
              shown.firstIndex { $0.uid == local }.map { $0 + 1 } == shown.firstIndex { $0.uid == copy?.uid })

        // Sort
        model.setColor(.blue, of: copy?.uid ?? local)
        model.connectionOrder = .color
        check("S-049 Sort By Color puts red before blue",
              model.ordered(model.savedConnections().filter { $0.groupID == first.uid }).first?.uid == local)
        model.connectionOrderReversed = true
        check("S-049 Reverse Order reverses it",
              model.ordered(model.savedConnections().filter { $0.groupID == first.uid }).first?.uid == copy?.uid)
        model.connectionOrder = .manual
        model.connectionOrderReversed = false

        // Default
        model.toggleDefault(socket)
        model.toggleDefault(local)
        check("S-049 one default connection at a time",
              model.savedConnections().filter(\.isDefault).map(\.uid) == [local])
        let fresh2 = Session()
        fresh2.showInitialConnection(model: model)
        check("S-049 a new window selects the default connection", fresh2.selectedSaved == local)
        model.toggleDefault(local)
        check("S-049 choosing the default again clears it", !model.savedConnections().contains(where: \.isDefault))

        // Export and import
        do {
            let data = try model.exportConnections()
            let text = String(decoding: data, as: UTF8.self)
            check("S-049 the export is Sequel Pro's format, without passwords",
                  text.contains("SPConnectionFavorites") && !text.contains("<key>password</key>")
                      && text.contains("<string>Work</string>"))
            let before = model.savedConnections().count
            let groupsBefore = model.connectionGroups().count
            let summary = try model.importConnections(data)
            let added = model.savedConnections().count - before
            check("S-049 Import adds every connection beside the ones there, reusing groups of the same name",
                  added == before && model.connectionGroups().count == groupsBefore, "\(summary), \(added) added")
            let imported = model.savedConnections().filter { $0.name == "Local Copy" }.last
            check("S-049 imported connections keep group and color, with no password",
                  imported?.groupID == first.uid && imported?.colorIndex == 4
                      && imported.map { PasswordStore.password(for: $0.uid) } == .some(nil))
            check("S-049 Import says how many", summary.hasPrefix("Imported \(added) connections in 1 group"), summary)
            for connection in model.savedConnections().suffix(added) { model.delete(connection.uid) }
        } catch {
            check("S-049 export and import", false, error.localizedDescription)
        }
        do {
            _ = try model.importConnections(Data("not a plist".utf8))
            check("S-049 a file with no connections says so", false)
        } catch {
            check("S-049 a file with no connections says so",
                  error.localizedDescription == "This file has no connections Quarry can read.", error.localizedDescription)
        }

        // Leave the store as the rest of the self-test expects it.
        if let copy { model.delete(copy.uid) }
        model.deleteGroup(first.uid)
        model.setColor(nil, of: local)
        session.show(saved: nil)
    }
}
