import AppKit
import QuarryKit
import SwiftUI

/// The database menu, then Tables, Views and Routines, filtered by the search field.
struct ObjectSidebar: View {
    @Environment(Session.self) private var session
    @Environment(AppModel.self) private var model
    @State private var filterFocused = false

    var body: some View {
        @Bindable var session = session
        let visible = session.visibleObjects
        List(selection: selection(visible)) {
            if session.database != nil {
                section("Tables", visible.filter { $0.kind == .table })
                section("Views", visible.filter { $0.kind == .view })
                section("Routines", visible.filter { $0.kind == .procedure || $0.kind == .function })
                if let problem = session.routinesProblem, !session.objects.isEmpty {
                    Section("Routines") {
                        Label("Unable to Load Routines", systemImage: StatusStyle.warningSymbol)
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.multicolor)
                            .lineLimit(1)
                            .help(problem.message)
                            .selectionDisabled()
                            .accessibilityLabel("Unable to load routines: \(problem.message)")
                    }
                }
            }
        }
        .contextMenu(forSelectionType: String.self, menu: rowMenu)
        .onDeleteCommand { if session.renamingObjectID == nil { session.requestDeleteTables() } }
        .searchable(text: $session.objectFilter, isPresented: $filterFocused, placement: .sidebar, prompt: "Filter")
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: Space.xs) {
                // S-049: the saved connection's color tag.
                if let saved = model.savedConnection(session.selectedSaved), let color = saved.color {
                    ConnectionColorDot(color: color)
                        .help("\(saved.displayName) is tagged \(color.title)")
                }
                DatabaseMenu()
                    .frame(maxWidth: .infinity)
                // S-068: a SQLite file has one database, so nothing to star.
                if session.database != nil, !session.isSQLite {
                    FavoriteDatabaseButton()
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.bottom, Space.sm)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Sequel Pro's + under the table list (S-021).
            if session.database != nil {
                HStack(spacing: Space.sm) {
                    let actions = session.objectActions()
                    Button("New Table…", systemImage: "plus") { session.requestNewTable() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(!actions.canCreate(.table))
                        .help("New Table (⌥⌘N)")
                    // S-030: views and routines in their own menu beside the +, so
                    // nothing hides behind a click and hold.
                    Menu {
                        Button("New View…") { session.requestNewDefinition(.view) }
                            .disabled(!actions.canCreate(.view))
                        Button("New Procedure…") { session.requestNewDefinition(.procedure) }
                            .disabled(!actions.canCreate(.procedure))
                            .serverOnly("New Procedure…", on: session.isSQLite)
                        Button("New Function…") { session.requestNewDefinition(.function) }
                            .disabled(!actions.canCreate(.function))
                            .serverOnly("New Function…", on: session.isSQLite)
                    } label: {
                        Label("New View, Procedure or Function", systemImage: "ellipsis.circle")
                    }
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(!ObjectKind.allCases.contains { $0 != .table && actions.canCreate($0) })
                    .help(session.isSQLite ? "New View (⌃⌥⌘V)" : "New View (⌃⌥⌘V), New Procedure (⌃⌥⌘P) or New Function (⌃⌥⌘U)")
                    Spacer()
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
            }
        }
        .overlay { emptyState(visible) }
        .background(CommandClickMonitor { row, outline in
            Self.objectID(atRow: row, in: outline, sections: sections(visible))
        } open: { session.openObjectInNewTab($0) })
        .onReceive(NotificationCenter.default.publisher(for: .focusSidebarFilter)) { note in
            if (note.object as AnyObject?) === session { filterFocused = true }
        }
    }

    /// ⇧-click selects several objects (S-022); the detail keeps the one it
    /// shows while it stays selected, else the first selected in list order.
    private func selection(_ visible: [DBObject]) -> Binding<Set<String>> {
        Binding(get: { session.sidebarSelection }, set: { ids in
            if session.renamingObjectID != nil { session.commitRename() }
            session.sidebarSelection = ids
            if let shown = session.selectedObjectID, ids.contains(shown) { return }
            session.selectedObjectID = visible.first { ids.contains($0.id) }?.id
        })
    }

    /// A row's context menu: Open in New Tab, then Rename, Duplicate, Empty
    /// and Delete for the clicked rows (the selection when a selected row was clicked).
    @ViewBuilder
    private func rowMenu(_ ids: Set<String>) -> some View {
        if ids.count == 1, let id = ids.first, let object = session.objects.first(where: { $0.id == id }) {
            Button(Session.openInNewTabTitle(object.kind)) { session.openObjectInNewTab(id) }
        }
        if !session.createStatementTargets(ids).isEmpty {
            Button("Show Create Statement…") { session.requestShowCreateStatement(ids) }
            Button("Copy Create Statement") { session.copyCreateStatement(ids) }
        }
        if session.canExport {
            Button("Export…") { session.requestExport(ids) }
        }
        let actions = session.objectActions(ids)
        if actions.definition != nil {
            Button(actions.editDefinitionTitle) { session.requestEditDefinition(ids) }
        }
        let operations = TableOperation.allCases.compactMap { op in session.tableOperationTitle(op, ids).map { (op, $0) } }
        if !operations.isEmpty {
            Menu("Maintenance") {
                ForEach(operations, id: \.0) { operation, title in
                    Button(title) { session.runTableOperation(operation, ids) }
                }
            }
        }
        if !actions.delete.isEmpty {
            Divider()
            if actions.rename != nil {
                Button(actions.renameTitle) { session.requestRenameTable(ids) }
            }
            if actions.duplicate != nil {
                Button("Duplicate Table…") { session.requestDuplicateTable(ids) }
            }
            if !actions.empty.isEmpty {
                Button(actions.emptyTitle) { session.requestEmptyTables(ids) }
            }
            Button(actions.deleteTitle, role: .destructive) { session.requestDeleteTables(ids) }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ objects: [DBObject]) -> some View {
        if !objects.isEmpty {
            Section(title) {
                ForEach(objects) { object in
                    Group {
                        if session.renamingObjectID == object.id {
                            Label {
                                RenameField()
                            } icon: {
                                Image(systemName: Self.symbol(object.kind))
                            }
                        } else {
                            Label(object.name, systemImage: Self.symbol(object.kind))
                                .lineLimit(1)
                                .help(object.name)
                                .accessibilityLabel("\(object.name), \(object.kind.rawValue)")
                        }
                    }
                    .tag(object.id)
                }
            }
        }
    }

    @ViewBuilder
    private func emptyState(_ visible: [DBObject]) -> some View {
        if session.database == nil {
            ContentUnavailableView {
                Label("Choose a Database", systemImage: "cylinder.split.1x2")
            } actions: {
                DatabaseMenu()
                    .fixedSize()
            }
        } else if let error = session.browseError, session.objects.isEmpty {
            ContentUnavailableView {
                Label("Unable to Load Tables", systemImage: StatusStyle.errorSymbol)
            } description: {
                Text(error.message).textSelection(.enabled)
            } actions: {
                Button("Try Again") { session.refresh() }
            }
        } else if session.isLoadingObjects, session.objects.isEmpty {
            ProgressView().controlSize(.small)
        } else if session.objects.isEmpty, !session.isLoadingObjects {
            ContentUnavailableView("No Tables", systemImage: "tablecells",
                                   description: Text(session.isSQLite && !session.isReadOnly
                                                     ? "Make one with New Table (⌥⌘N)." : "This database is empty."))
        } else if visible.isEmpty {
            ContentUnavailableView {
                Label("No Objects Match \u{201C}\(session.objectFilter)\u{201D}", systemImage: "magnifyingglass")
            } actions: {
                Button("Clear Filter") { session.objectFilter = "" }
            }
        }
    }

    /// The objects of each section, in the order the list shows them.
    private func sections(_ visible: [DBObject]) -> [[DBObject]] {
        [visible.filter { $0.kind == .table }, visible.filter { $0.kind == .view },
         visible.filter { $0.kind == .procedure || $0.kind == .function }].filter { !$0.isEmpty }
    }

    /// The object on a row of the list: headers are level 0, their objects level 1.
    /// Collapsed sections show no children, so count rows, never assume them.
    static func objectID(atRow row: Int, in outline: NSOutlineView, sections: [[DBObject]]) -> String? {
        guard row >= 0, row < outline.numberOfRows else { return nil }
        var section = -1, index = 0
        for current in 0...row {
            if outline.level(forRow: current) == 0 {
                section += 1
                index = 0
                if current == row { return nil }
            } else if current == row {
                guard sections.indices.contains(section), sections[section].indices.contains(index) else { return nil }
                return sections[section][index].id
            } else {
                index += 1
            }
        }
        return nil
    }

    static func symbol(_ kind: ObjectKind) -> String {
        switch kind {
        case .table: "tablecells"
        case .view: "eye"
        case .procedure: "gearshape"
        case .function: "function"
        }
    }
}

/// Rename Table in place (S-022): Return renames, Escape cancels, and
/// leaving the field renames, as in the Finder.
private struct RenameField: View {
    @Environment(Session.self) private var session
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var session = session
        TextField("Table name", text: $session.renameText)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { session.commitRename() }
            .onExitCommand { session.cancelRename() }
            .onAppear { focused = true }
            .onChange(of: focused) { _, now in
                if !now, session.renamingObjectID != nil { session.commitRename() }
            }
            .accessibilityLabel("Table name")
    }
}

/// The current database, as a pop-up menu: favorites first, then the rest.
struct DatabaseMenu: View {
    @Environment(Session.self) private var session
    /// Not a name a database can have: names cannot hold U+0000.
    private static let newDatabaseTag = "\u{0}new-database"

    var body: some View {
        let favorites = session.favoriteDatabases
        // "New Database…" sits in the menu as Sequel Pro's Add Database… did;
        // choosing it opens the sheet and keeps the current database.
        let selection = Binding<String?>(
            get: { session.database },
            set: { name in
                if name == Self.newDatabaseTag { session.requestNewDatabase() } else { session.database = name }
            })
        Picker("Database", selection: selection) {
            if session.database == nil {
                Text("Choose Database").tag(String?.none)
            }
            let starred = session.databases.filter(favorites.contains)
            if !starred.isEmpty {
                Section("Favorites") {
                    ForEach(starred, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
            }
            Section {
                ForEach(session.databases.filter { !favorites.contains($0) }, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            // S-068: a SQLite file holds one database, main.
            if !session.isSQLite {
                Divider()
                Text("New Database…").tag(String?.some(Self.newDatabaseTag))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .help("Choose the database to browse")
        .accessibilityLabel("Database")
    }
}

/// The star beside the database menu: Add to Favorites / Remove from Favorites (⌘D).
struct FavoriteDatabaseButton: View {
    @Environment(Session.self) private var session

    var body: some View {
        let starred = session.isFavoriteDatabase
        let name = session.database ?? ""
        Button(starred ? "Remove from Favorites" : "Add to Favorites",
               systemImage: starred ? "star.fill" : "star") {
            session.toggleFavoriteDatabase()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(starred ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
        .help(starred ? "Remove \(name) from Favorites (⌘D)" : "Add \(name) to Favorites, to find it first and open it from the Connect page (⌘D)")
        .accessibilityValue(starred ? "Favorite" : "")
    }
}

/// ⌘-click on a sidebar row opens it in a new tab (S-037). The click is taken
/// before the list sees it: letting the list select the row and refusing the
/// change left the row drawn as selected (docs/FIXLOG.md).
private struct CommandClickMonitor: NSViewRepresentable {
    let objectAt: (_ row: Int, _ outline: NSOutlineView) -> String?
    let open: (String) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.objectAt = objectAt
        probe.open = open
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.objectAt = objectAt
        probe.open = open
    }

    final class Probe: NSView {
        var objectAt: (Int, NSOutlineView) -> String? = { _, _ in nil }
        var open: (String) -> Void = { _ in }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        /// True when the event was a ⌘-click on an object row of this sidebar.
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, event.clickCount == 1,
                  event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  let root = window.contentView?.superview,
                  let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)) else { return false }
            var view: NSView? = hit
            while let current = view, !(current is NSOutlineView) { view = current.superview }
            // The sidebar's list is the outline view under this probe.
            guard let outline = view as? NSOutlineView,
                  let scroll = outline.enclosingScrollView,
                  scroll.convert(scroll.bounds, to: nil).contains(convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)) else { return false }
            let row = outline.row(at: outline.convert(event.locationInWindow, from: nil))
            guard let id = objectAt(row, outline) else { return false }
            open(id)
            return true
        }
    }
}
