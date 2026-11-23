import Foundation
import QuarryKit
import SwiftData

/// A group of saved connections on the Connect page (S-049): one level, a
/// collapsible sidebar section. Connections point at it by `groupID`.
@Model
final class ConnectionGroup {
    var uid: UUID = UUID()
    var name: String = ""
    var order: Int = 0
    var isExpanded: Bool = true
    var createdAt: Date = Date.now

    init(name: String, order: Int) {
        self.name = name
        self.order = order
    }
}

/// Organizing saved connections (S-049): groups, colors, order, the default,
/// and Sequel Pro's favorites files.
extension AppModel {
    func connectionGroups() -> [ConnectionGroup] {
        let descriptor = FetchDescriptor<ConnectionGroup>(sortBy: [SortDescriptor(\.order), SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Groups in the chosen order: Manual keeps theirs, every other order sorts them by name.
    func ordered(_ groups: [ConnectionGroup]) -> [ConnectionGroup] {
        guard connectionOrder != .manual else { return connectionOrderReversed ? groups.reversed() : groups }
        let sorted = groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return connectionOrderReversed ? sorted.reversed() : sorted
    }

    /// One section's connections in the chosen order.
    func ordered(_ connections: [SavedConnection]) -> [SavedConnection] {
        let items = connections.map {
            ConnectionOrder.Item(name: $0.displayName, host: $0.kind == .socket ? $0.socket : $0.host,
                                 transport: $0.kind, colorIndex: $0.colorIndex, order: $0.order)
        }
        return connectionOrder.sorted(items, reversed: connectionOrderReversed).map { connections[$0] }
    }

    /// New Group: "New Group" (or the next free number), ready to rename, with `moving` in it.
    @discardableResult
    func newGroup(moving uid: UUID?) -> ConnectionGroup {
        let groups = connectionGroups()
        let group = ConnectionGroup(name: ConnectionFile.newGroupName(after: groups.map(\.name)),
                                    order: (groups.map(\.order).max() ?? -1) + 1)
        context.insert(group)
        if let connection = savedConnection(uid) { connection.groupID = group.uid }
        try? context.save()
        return group
    }

    func renameGroup(_ uid: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let group = connectionGroups().first(where: { $0.uid == uid }) { group.name = name }
        try? context.save()
    }

    /// Delete Group: its connections move to the top level, so nothing is lost.
    func deleteGroup(_ uid: UUID) {
        for connection in savedConnections() where connection.groupID == uid { connection.groupID = nil }
        if let group = connectionGroups().first(where: { $0.uid == uid }) { context.delete(group) }
        try? context.save()
    }

    func move(_ uid: UUID, toGroup group: UUID?) {
        guard let connection = savedConnection(uid) else { return }
        connection.groupID = group
        connection.order = (savedConnections().filter { $0.groupID == group }.map(\.order).max() ?? -1) + 1
        try? context.save()
    }

    func renameConnection(_ uid: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { savedConnection(uid)?.name = name }
        try? context.save()
    }

    func setColor(_ color: ConnectionColor?, of uid: UUID) {
        savedConnection(uid)?.colorIndex = color?.rawValue ?? -1
        try? context.save()
    }

    /// Default Connection: one at most; choosing the default again clears it.
    func toggleDefault(_ uid: UUID) {
        let all = savedConnections()
        let wasDefault = all.first { $0.uid == uid }?.isDefault ?? false
        for connection in all { connection.isDefault = !wasDefault && connection.uid == uid }
        try? context.save()
    }

    /// Settings > General's Default connection (S-054): this one, or none.
    func setDefaultConnection(_ uid: UUID?) {
        for connection in savedConnections() { connection.isDefault = connection.uid == uid }
        try? context.save()
    }

    /// What a new window selects: the default, else the connection used last.
    func initialConnection() -> SavedConnection? {
        let all = savedConnections()
        return all.first(where: \.isDefault)
            ?? all.filter { $0.lastUsedAt != nil }.max { $0.lastUsedAt! < $1.lastUsedAt! }
    }

    /// Duplicate Connection: "Local Copy" beside the original, with its group, color and passwords.
    @discardableResult
    func duplicateConnection(_ uid: UUID) -> SavedConnection? {
        guard let original = savedConnection(uid) else { return nil }
        let all = savedConnections()
        var details = original.details
        details.name = ConnectionFile.copyName(of: original.displayName, among: all.map(\.displayName))
        let copy = SavedConnection(details: details)
        copy.groupID = original.groupID
        copy.colorIndex = original.colorIndex
        for later in all where later.groupID == original.groupID && later.order > original.order { later.order += 1 }
        copy.order = original.order + 1
        context.insert(copy)
        PasswordStore.store(details, for: copy.uid)
        try? context.save()
        return copy
    }

    /// Manual order: rows dragged within one section, as `onMove` reports them.
    func moveConnections(_ shown: [SavedConnection], from source: IndexSet, to destination: Int) {
        var rows = shown
        rows.move(fromOffsets: source, toOffset: destination)
        for (index, connection) in rows.enumerated() { connection.order = index }
        connectionOrder = .manual
        connectionOrderReversed = false
        try? context.save()
    }

    // MARK: Files

    /// Export Connections…: every connection and group, without passwords.
    func exportConnections() throws -> Data {
        let groups = connectionGroups()
        let names = Dictionary(uniqueKeysWithValues: groups.map { ($0.uid, $0.name) })
        let top = ordered(savedConnections().filter { $0.groupID == nil })
        let grouped = groups.flatMap { group in ordered(savedConnections().filter { $0.groupID == group.uid }) }
        let entries = (top + grouped).map {
            ConnectionFile.Entry(group: $0.groupID.flatMap { names[$0] } ?? "", details: $0.fields, colorIndex: $0.colorIndex)
        }
        return try ConnectionFile.encode(entries, groups: groups.map(\.name))
    }

    /// Import Connections…: adds the file's connections beside the ones here,
    /// into groups of the same name (made when missing). Returns the alert's text.
    func importConnections(_ data: Data) throws -> String {
        let (entries, groupNames) = try ConnectionFile.decode(data)
        var groups = Dictionary(connectionGroups().map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var order = (connectionGroups().map(\.order).max() ?? -1) + 1
        var used: Set<String> = []
        for name in groupNames + entries.map(\.group) where !name.isEmpty && groups[name] == nil {
            let group = ConnectionGroup(name: name, order: order)
            order += 1
            context.insert(group)
            groups[name] = group
        }
        var next = (savedConnections().map(\.order).max() ?? -1) + 1
        for entry in entries {
            let saved = SavedConnection(details: entry.details)
            saved.colorIndex = entry.colorIndex
            saved.order = next
            next += 1
            if !entry.group.isEmpty {
                saved.groupID = groups[entry.group]?.uid
                used.insert(entry.group)
            }
            context.insert(saved)
        }
        try? context.save()
        return ConnectionFile.summary(connections: entries.count, groups: used.count)
    }
}
