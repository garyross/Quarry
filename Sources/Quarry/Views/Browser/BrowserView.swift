import QuarryKit
import QuarryControllers
import SwiftUI

/// The connected window: objects in the sidebar, the current view in the detail.
struct BrowserView: View {
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var session = session
        NavigationSplitView {
            ObjectSidebar()
                .navigationSplitViewColumnWidth(min: Layout.sidebarMin, ideal: Layout.sidebarIdeal, max: Layout.sidebarMax)
        } detail: {
            DetailContainer()
                .sheet(item: $session.fieldEditor) { editor in
                    FieldEditorSheet(editor: editor) { session.fieldEditor = nil }
                }
                .sheet(item: $session.bitEditor) { editor in
                    BitEditorSheet(editor: editor) { session.bitEditor = nil }
                }
                .sheet(item: $session.goToDatabase) { finder in
                    GoToDatabaseSheet(finder: finder, open: { session.openFoundDatabase() },
                                      close: { session.goToDatabase = nil })
                }
                .sheet(item: $session.newTable) { creator in
                    NewTableSheet(creator: creator, create: { session.createTable() },
                                  close: { session.newTable = nil })
                }
                .sheet(item: $session.definitionDraft) { draft in
                    DefinitionSheet(draft: draft, save: { session.saveDefinition() },
                                    close: { session.definitionDraft = nil })
                        .interactiveDismissDisabled(draft.isSaving)
                }
                .sheet(item: $session.newDatabase) { creator in
                    NewDatabaseSheet(creator: creator, create: { session.createDatabase() },
                                     close: { session.newDatabase = nil })
                }
                .sheet(item: $session.databaseEditor) { editor in
                    DatabaseEditorSheet(editor: editor, run: { session.runDatabaseEditor() },
                                        close: { session.databaseEditor = nil })
                        .interactiveDismissDisabled(editor.isWorking)
                }
                .sheet(item: $session.serverVariables) { list in
                    ServerVariablesSheet(list: list, close: { session.serverVariables = nil })
                }
                .sheet(item: $session.userManager) { manager in
                    UserAccountsSheet(manager: manager, apply: { session.applyUserAccounts() },
                                      confirmDelete: { session.confirmApplyUserAccounts() },
                                      close: { session.userManager = nil })
                        .interactiveDismissDisabled(manager.isApplying)
                }
                .sheet(item: $session.tableDuplicator) { duplicator in
                    DuplicateTableSheet(duplicator: duplicator, run: { session.runDuplicateTable() },
                                        close: { session.tableDuplicator = nil })
                        .interactiveDismissDisabled(duplicator.isWorking)
                }
                .sheet(item: $session.saveQueryDraft) { draft in
                    SaveQuerySheet(draft: draft, save: { session.saveQuery() }, close: { session.saveQueryDraft = nil })
                }
                .sheet(item: $session.exporter) { exporter in
                    ExportSheet(exporter: exporter, close: { session.exporter = nil })
                        .interactiveDismissDisabled(exporter.isWorking)
                }
                .sheet(item: $session.importer) { importer in
                    ImportSheet(importer: importer, close: { session.closeImport() })
                        .interactiveDismissDisabled(importer.isWorking)
                }
                .sheet(item: $session.createStatementSheet) { sheet in
                    CreateStatementSheet(sheet: sheet, close: { session.createStatementSheet = nil })
                }
                .sheet(isPresented: $session.connectionLost) {
                    ConnectionLostSheet(session: session)
                        .interactiveDismissDisabled()
                }
                .frame(minWidth: Layout.detailMin)
                // Not `.inspector`: SwiftUI's inspector in a NavigationSplitView detail
                // can loop on its column sizes and crash (docs/FIXLOG.md).
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    if session.showsDatabaseInfo {
                        HStack(spacing: 0) {
                            Divider()
                            DatabaseInfoView()
                                .frame(width: Layout.databaseInfoWidth)
                        }
                        .transition(.move(edge: .trailing))
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button("Back", systemImage: "chevron.backward") { session.goBack() }
                            .keyboardShortcut(session.view == .query ? nil : KeyboardShortcut("["))
                            .disabled(!session.history.canGoBack)
                            .help("Go back to the database, table or view you showed before (⌃⌥← or ⌘[)")
                        Button("Forward", systemImage: "chevron.forward") { session.goForward() }
                            .keyboardShortcut(session.view == .query ? nil : KeyboardShortcut("]"))
                            .disabled(!session.history.canGoForward)
                            .help("Go forward again (⌃⌥→ or ⌘])")
                    }
                    ToolbarItem(placement: .principal) {
                        Picker("View", selection: $session.view) {
                            ForEach(DetailView.allCases) { view in
                                Label(view.title, systemImage: view.symbol)
                                    .help(view.help)
                                    .tag(view)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelStyle(.iconOnly)
                        .help("Switch views (⌘1–⌘6)")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Refresh", systemImage: "arrow.clockwise") { session.refresh() }
                            .help("Reload the databases, objects and the current view (⇧⌘R)")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Toggle(isOn: $session.showsDatabaseInfo) {
                            Label("Database Information", systemImage: "cylinder.split.1x2")
                        }
                        .help(session.isSQLite ? "Show the file's size, pages and settings, and tools to check, vacuum and optimize it (⌥⌘I)"
                              : "Show the database's size and character set, and tools to check, repair and tidy it (⌥⌘I)")
                        .disabled(session.database == nil)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Console", systemImage: "terminal") { openWindow(id: ConsoleWindow.sceneID) }
                            .help("Show every statement Quarry sent to the server (⇧⌘K)")
                    }
                }
        }
    }
}

/// The current view for the selected object, or why there is nothing to show.
struct DetailContainer: View {
    @Environment(Session.self) private var session

    var body: some View {
        let object = session.selectedObject
        Group {
            if session.view == .query {
                QueryView()
            } else if session.database == nil {
                ContentUnavailableView("Choose a Database", systemImage: "cylinder.split.1x2",
                                       description: Text("Pick one from the menu at the top of the sidebar."))
            } else if object == nil {
                ContentUnavailableView("Select a Table", systemImage: "tablecells",
                                       description: Text("Or press ⌘6 to write a query."))
            } else if let object, !session.view.applies(to: object.kind) {
                ContentUnavailableView("Nothing to Show", systemImage: session.view.symbol,
                                       description: Text("\(session.view.title) is for tables. \(object.name) is a \(object.kind.rawValue)."))
            } else {
                switch session.view {
                case .structure: StructureView()
                case .content: TableContentView()
                case .foreignKeys: ForeignKeysView()
                case .triggers: TriggersView()
                case .info: InfoView()
                case .query: QueryView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A slim bar under a grid: what is shown, and the page controls.
struct StatusBar<Leading: View, Trailing: View>: View {
    let text: String
    var isLoading = false
    /// Buttons before the text, like Content's add and delete row.
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Space.sm) {
            leading
            if isLoading {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Loading")
            }
            Text(text)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityLabel(text)
            Spacer(minLength: Space.sm)
            trailing
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
        .frame(minHeight: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

extension StatusBar where Leading == EmptyView {
    init(text: String, isLoading: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.init(text: text, isLoading: isLoading, leading: { EmptyView() }, trailing: trailing)
    }
}

extension StatusBar where Leading == EmptyView, Trailing == EmptyView {
    init(text: String, isLoading: Bool = false) {
        self.init(text: text, isLoading: isLoading, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// A grid with its loading, error and empty states.
struct GridPane: View {
    let data: GridData
    let load: LoadState
    let emptyTitle: String
    let emptySymbol: String
    var sort: (key: String, ascending: Bool)?
    var onSort: ((String, Bool) -> Void)?
    var editing: DataGrid.Editing?
    var rowActions: DataGrid.RowActions?
    var insertTable: DataGrid.InsertTarget?
    var reports = DataGrid.Reports()
    var editRequest: (row: Int, column: Int, id: UUID)?
    var fieldEditor: DataGrid.FieldEditorHook?
    var links: DataGrid.LinkHook?
    var selectRequest: (row: Int, id: UUID)?
    var reorder: DataGrid.RowReorder?
    /// A button in the empty state, like "Add Row".
    var emptyAction: (title: String, action: () -> Void)?

    var body: some View {
        DataGrid(data: data, sort: sort, onSort: onSort, editing: editing, rowActions: rowActions,
                 insertTable: insertTable, reports: reports, fieldEditor: fieldEditor, links: links,
                 editRequest: editRequest, selectRequest: selectRequest, reorder: reorder,
                 accessibilityLabel: emptyTitle)
            .opacity(load.isLoading ? 0.5 : 1)
            .overlay {
                if let error = load.error {
                    ErrorMessage(error: error)
                        .padding(Space.xl)
                        .frame(maxWidth: Layout.connectFormWidth)
                } else if data.rows.isEmpty, !load.isLoading, load.loadedFor != nil {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: emptySymbol)
                    } actions: {
                        if let emptyAction {
                            Button(emptyAction.title, action: emptyAction.action)
                        }
                    }
                }
            }
    }
}
