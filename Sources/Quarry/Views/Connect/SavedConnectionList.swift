import QuarryKit
import SwiftData
import SwiftUI

/// Saved connections, ungrouped first, then each group as a collapsible
/// section (S-049), then favorite databases (S-060). Double-click or Return
/// connects; Delete asks first for a connection and removes a favorite at once.
struct SavedConnectionList: View {
    @Environment(AppModel.self) private var model
    @Environment(Session.self) private var session
    @Query(sort: [SortDescriptor(\SavedConnection.name), SortDescriptor(\SavedConnection.createdAt)])
    private var saved: [SavedConnection]
    @Query(sort: [SortDescriptor(\ConnectionGroup.order), SortDescriptor(\ConnectionGroup.createdAt)])
    private var groups: [ConnectionGroup]

    var body: some View {
        let favorites = model.favorites
        let groupIDs = Set(groups.map(\.uid))
        let top = model.ordered(saved.filter { $0.groupID.map { !groupIDs.contains($0) } ?? true })
        List(selection: selection) {
            if !top.isEmpty {
                Section("Connections") { rows(top) }
            }
            ForEach(model.ordered(groups)) { group in
                Section(isExpanded: expanded(group)) {
                    rows(model.ordered(saved.filter { $0.groupID == group.uid }))
                } header: {
                    header(group)
                }
            }
            if !favorites.isEmpty {
                Section("Favorite Databases") {
                    ForEach(favorites) { favorite in
                        FavoriteRow(favorite: favorite).tag(favorite.uid)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let connection = saved.first(where: { $0.uid == id }) {
                Button("Connect") { connect(connection) }
                Divider()
                ConnectionCommands(model: model, session: session, uid: connection.uid)
                Divider()
                ConnectionListCommands(model: model, session: session)
            } else if let id = ids.first, let favorite = model.favorite(id) {
                Button("Connect") { connect(favorite) }
                Divider()
                Button("Remove from Favorites") { remove(favorite) }
            } else {
                ConnectionListCommands(model: model, session: session)
            }
        } primaryAction: { ids in
            if let id = ids.first, let connection = saved.first(where: { $0.uid == id }) {
                connect(connection)
            } else if let id = ids.first, let favorite = model.favorite(id) {
                connect(favorite)
            }
        }
        .onDeleteCommand {
            if let favorite = model.favorite(session.selectedFavorite) {
                remove(favorite)
            } else {
                session.requestDeleteSelectedConnection()
            }
        }
        .overlay {
            if saved.isEmpty, favorites.isEmpty, groups.isEmpty {
                ContentUnavailableView("No Saved Connections", systemImage: "server.rack",
                                       description: Text("Fill in the form and choose Save Connection."))
            }
        }
        .confirmationDialog(
            "Delete Connection \u{201C}\(model.savedConnection(session.pendingDeleteSaved)?.displayName ?? "")\u{201D}?",
            isPresented: Binding(get: { session.pendingDeleteSaved != nil }, set: { if !$0 { session.pendingDeleteSaved = nil } })
        ) {
            Button("Delete", role: .destructive) { session.deletePendingConnection(model: model) }
            Button("Cancel", role: .cancel) { session.pendingDeleteSaved = nil }
        } message: {
            Text("The connection and its saved password are removed. The server is not changed.")
        }
    }

    /// One section's rows; dragging them sets Manual order.
    private func rows(_ shown: [SavedConnection]) -> some View {
        ForEach(shown) { connection in
            ConnectionRow(connection: connection).tag(connection.uid)
        }
        .onMove { source, destination in model.moveConnections(shown, from: source, to: destination) }
    }

    private func header(_ group: ConnectionGroup) -> some View {
        Group {
            if session.renamingGroup == group.uid {
                NameField(label: "Group name", name: group.name) { name in
                    if let name { model.renameGroup(group.uid, to: name) }
                    session.renamingGroup = nil
                }
            } else {
                Text(group.name)
            }
        }
        .contextMenu {
            Button("Rename Group") {
                session.renamingConnection = nil
                session.renamingGroup = group.uid
            }
            Button("Delete Group") { model.deleteGroup(group.uid) }
                .help("Its connections move to Connections.")
            Divider()
            ConnectionListCommands(model: model, session: session)
        }
    }

    private func expanded(_ group: ConnectionGroup) -> Binding<Bool> {
        Binding(get: { group.isExpanded }, set: { group.isExpanded = $0; try? model.context.save() })
    }

    /// Selecting a row fills the form.
    private var selection: Binding<UUID?> {
        Binding(get: { session.selectedSaved ?? session.selectedFavorite },
                set: { id in
                    if let favorite = model.favorite(id) {
                        session.show(favorite: favorite)
                    } else {
                        session.show(saved: saved.first { $0.uid == id })
                    }
                })
    }

    private func connect(_ connection: SavedConnection) {
        session.show(saved: connection)
        session.connect(model: model)
    }

    private func connect(_ favorite: FavoriteDatabase) {
        session.show(favorite: favorite)
        session.connect(model: model)
    }

    /// A favorite holds no data; removing it needs no confirmation.
    private func remove(_ favorite: FavoriteDatabase) {
        if session.selectedFavorite == favorite.uid { session.show(saved: nil) }
        model.removeFavorite(favorite.uid)
    }
}

/// A saved connection: its name (renamed in place), where it is, and its color as a dot, as Finder tags.
private struct ConnectionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Session.self) private var session
    let connection: SavedConnection

    var body: some View {
        let summary = connection.summary + (connection.isDefault ? " · Default" : "")
        HStack(spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 0) {
                if session.renamingConnection == connection.uid {
                    NameField(label: "Connection name", name: connection.displayName) { name in
                        if let name {
                            model.renameConnection(connection.uid, to: name)
                            if session.selectedSaved == connection.uid { session.form.name = connection.name }
                        }
                        session.renamingConnection = nil
                    }
                } else {
                    Text(connection.displayName)
                        .lineLimit(1)
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let color = connection.color {
                ConnectionColorDot(color: color)
            }
        }
        .help("\(connection.displayName) — \(summary)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel([connection.displayName, connection.summary, connection.color?.title,
                             connection.isDefault ? "default connection" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}

private struct FavoriteRow: View {
    let favorite: FavoriteDatabase

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(favorite.database)
                    .lineLimit(1)
                Text(favorite.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help("\(favorite.database) — \(favorite.summary)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(favorite.database), favorite database, \(favorite.summary)")
    }
}

/// A connection's color tag (S-049).
struct ConnectionColorDot: View {
    let color: ConnectionColor

    var body: some View {
        Image(systemName: "circle.fill")
            .imageScale(.small)
            .foregroundStyle(color.tint)
            .accessibilityHidden(true)
    }
}

extension ConnectionColor {
    /// System colors, so the tags follow light and dark mode.
    var tint: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}

/// A name edited in place, as in the Finder: Return or leaving the field
/// saves, Escape cancels (`done(nil)`).
private struct NameField: View {
    let label: String
    let done: (String?) -> Void
    @State private var text: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(label: String, name: String, done: @escaping (String?) -> Void) {
        self.label = label
        self.done = done
        _text = State(initialValue: name)
    }

    var body: some View {
        TextField(label, text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { finish(text) }
            .onExitCommand { finish(nil) }
            .onAppear { focused = true }
            .onChange(of: focused) { _, now in if !now { finish(text) } }
            .accessibilityLabel(label)
    }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        done(value)
    }
}

/// The commands on one saved connection: in its row menu and the Connection menu.
struct ConnectionCommands: View {
    let model: AppModel
    let session: Session
    let uid: UUID?

    var body: some View {
        let connection = model.savedConnection(uid)
        Group {
            items(connection, uid: uid ?? UUID())
        }
        .disabled(connection == nil)
    }

    @ViewBuilder
    private func items(_ connection: SavedConnection?, uid: UUID) -> some View {
        Button("Rename Connection") {
            session.show(saved: connection)
            session.renameSelectedConnection()
        }
        Button("Duplicate Connection") {
            session.show(saved: connection)
            session.duplicateSelectedConnection(model: model)
        }
        .keyboardShortcut("d", modifiers: [.command, .option, .control])
        Menu("Color") {
            ForEach(ConnectionColor.allCases) { color in
                Toggle(color.title, isOn: Binding(get: { connection?.colorIndex == color.rawValue },
                                                  set: { _ in model.setColor(color, of: uid) }))
            }
            Divider()
            Toggle("None", isOn: Binding(get: { connection?.color == nil }, set: { _ in model.setColor(nil, of: uid) }))
        }
        Menu("Move to Group") {
            ForEach(model.ordered(model.connectionGroups())) { group in
                Toggle(group.name, isOn: Binding(get: { connection?.groupID == group.uid },
                                                 set: { _ in model.move(uid, toGroup: group.uid) }))
            }
            Divider()
            Toggle("None", isOn: Binding(get: { connection?.groupID == nil }, set: { _ in model.move(uid, toGroup: nil) }))
        }
        Toggle("Default Connection", isOn: Binding(get: { connection?.isDefault ?? false },
                                                   set: { _ in model.toggleDefault(uid) }))
        Divider()
        Button("Delete Connection…", role: .destructive) {
            session.show(saved: connection)
            session.requestDeleteSelectedConnection()
        }
    }
}

/// The commands on the whole list: groups, order and files.
struct ConnectionListCommands: View {
    @Bindable var model: AppModel
    let session: Session

    var body: some View {
        Button("New Group") { session.newConnectionGroup(model: model) }
            .keyboardShortcut("n", modifiers: [.command, .option, .control])
        Menu("Sort By") {
            Picker("Sort By", selection: $model.connectionOrder) {
                ForEach(ConnectionOrder.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Toggle("Reverse Order", isOn: $model.connectionOrderReversed)
        }
        Divider()
        Button("Import Connections…") { session.importConnections(model: model) }
        Button("Export Connections…") { session.exportConnections(model: model) }
    }
}
